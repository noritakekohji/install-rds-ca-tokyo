BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-RdsSqlServerCa.ps1'
    . $scriptPath

    $script:tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null

    $script:expectedName = 'Amazon RDS us-east-1 Root CA RSA2048 G1'
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=$script:expectedName",
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true)
    )
    $script:testCertificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
    $script:testCollection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    [void]$script:testCollection.Add($script:testCertificate)

    $script:p7bPath = Join-Path $script:tempDirectory 'custom-bundle.p7b'
    [System.IO.File]::WriteAllBytes(
        $script:p7bPath,
        $script:testCollection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7)
    )
    $pemBase64 = [Convert]::ToBase64String($script:testCertificate.RawData)
    $pemLines = [regex]::Matches($pemBase64, '.{1,64}') | ForEach-Object Value
    $script:pemPath = Join-Path $script:tempDirectory 'custom-bundle.pem'
    $pem = "-----BEGIN CERTIFICATE-----`n$($pemLines -join "`n")`n-----END CERTIFICATE-----`n"
    [System.IO.File]::WriteAllText($script:pemPath, $pem, [System.Text.Encoding]::ASCII)
}

AfterAll {
    if ($script:tempDirectory -and (Test-Path -LiteralPath $script:tempDirectory)) {
        Remove-Item -LiteralPath $script:tempDirectory -Recurse -Force
    }
}

Describe 'Resolve-RdsBundlePath' {
    It 'uses an explicit bundle path before files beside the script' {
        $scriptDirectory = Join-Path $script:tempDirectory 'script-folder'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $scriptDirectory 'global-bundle.p7b'), 'default')

        Resolve-RdsBundlePath -RequestedPath $script:pemPath -ScriptDirectory $scriptDirectory |
            Should -Be (Resolve-Path -LiteralPath $script:pemPath).Path
    }

    It 'prefers the default PKCS#7 bundle beside the script' {
        $scriptDirectory = Join-Path $script:tempDirectory 'p7b-folder'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        $defaultPath = Join-Path $scriptDirectory 'global-bundle.p7b'
        [System.IO.File]::WriteAllText($defaultPath, 'default')
        [System.IO.File]::WriteAllText((Join-Path $scriptDirectory 'global-bundle.pem'), 'fallback')

        Resolve-RdsBundlePath -RequestedPath '' -ScriptDirectory $scriptDirectory |
            Should -Be (Resolve-Path -LiteralPath $defaultPath).Path
    }

    It 'uses the default PEM beside the script when no PKCS#7 file exists' {
        $scriptDirectory = Join-Path $script:tempDirectory 'pem-folder'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        $defaultPath = Join-Path $scriptDirectory 'global-bundle.pem'
        [System.IO.File]::WriteAllText($defaultPath, 'bundle')

        Resolve-RdsBundlePath -RequestedPath '' -ScriptDirectory $scriptDirectory |
            Should -Be (Resolve-Path -LiteralPath $defaultPath).Path
    }

    It 'does not fall back when an explicitly specified path is missing' {
        $scriptDirectory = Join-Path $script:tempDirectory 'missing-explicit-folder'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $scriptDirectory 'global-bundle.p7b'), 'default')

        { Resolve-RdsBundlePath -RequestedPath (Join-Path $script:tempDirectory 'missing.pem') -ScriptDirectory $scriptDirectory } |
            Should -Throw '*No fallback file was used*'
    }

    It 'prompts for a path when no default bundle exists' {
        $scriptDirectory = Join-Path $script:tempDirectory 'prompt-folder'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        Mock Read-Host { $script:pemPath }

        Resolve-RdsBundlePath -RequestedPath '' -ScriptDirectory $scriptDirectory |
            Should -Be (Resolve-Path -LiteralPath $script:pemPath).Path
    }
}

Describe 'Import-RdsCaCertificate' {
    It 'reads a PKCS#7 certificate bundle' {
        (Import-RdsCaCertificate -Path $script:p7bPath).Count | Should -Be 1
    }

    It 'reads a PEM containing one certificate' {
        (Import-RdsCaCertificate -Path $script:pemPath).Count | Should -Be 1
    }

    It 'rejects a PEM without certificate blocks' {
        $invalidPath = Join-Path $script:tempDirectory 'invalid.pem'
        [System.IO.File]::WriteAllText($invalidPath, 'not a certificate')

        { Import-RdsCaCertificate -Path $invalidPath } | Should -Throw '*No PEM certificate was found*'
    }
}

Describe 'Get-RdsRootCertificate' {
    It 'accepts the selected self-issued root with its matching thumbprint' {
        $certificate = Get-RdsRootCertificate `
            -Certificates $script:testCollection `
            -ExpectedCommonName $script:expectedName `
            -VerifiedThumbprint $script:testCertificate.Thumbprint

        $certificate.Thumbprint | Should -Be $script:testCertificate.Thumbprint
    }

    It 'rejects a certificate with a mismatched thumbprint' {
        { Get-RdsRootCertificate `
            -Certificates $script:testCollection `
            -ExpectedCommonName $script:expectedName `
            -VerifiedThumbprint ('0' * 40) } | Should -Throw '*does not match the configured AWS thumbprint*'
    }

    It 'rejects a single unrelated certificate instead of installing it' {
        { Get-RdsRootCertificate `
            -Certificates $script:testCollection `
            -ExpectedCommonName 'Amazon RDS ap-northeast-1 Root CA RSA2048 G1' `
            -VerifiedThumbprint $script:testCertificate.Thumbprint } | Should -Throw '*found 0*Nothing was installed*'
    }
}
