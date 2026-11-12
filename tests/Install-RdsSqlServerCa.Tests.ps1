BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-RdsSqlServerCa.ps1'
    $script:tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null

    $subject = 'CN=Amazon RDS us-east-1 Root CA RSA2048 G1'
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        $subject,
        $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true)
    )
    $testCertificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
    $script:thumbprint = $testCertificate.Thumbprint
    $collection = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
    [void]$collection.Add($testCertificate)
    $bundleBytes = $collection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7)
    $script:bundlePath = Join-Path $script:tempDirectory 'test-bundle.p7b'
    [System.IO.File]::WriteAllBytes($script:bundlePath, $bundleBytes)

    function Invoke-InstallerProcess {
        param([string]$VerifiedThumbprint, [string]$ExtraArgument = '-WhatIf')

        $outputPath = Join-Path $script:tempDirectory ([Guid]::NewGuid().ToString('N') + '.out.txt')
        $errorPath = Join-Path $script:tempDirectory ([Guid]::NewGuid().ToString('N') + '.err.txt')
        $arguments = @(
            '-NoProfile', '-File', ('"{0}"' -f $scriptPath),
            '-BundlePath', ('"{0}"' -f $script:bundlePath),
            '-Region', 'us-east-1',
            '-CaIdentifier', 'rds-ca-rsa2048-g1',
            '-ExpectedThumbprint', $VerifiedThumbprint
        )
        if ($ExtraArgument) { $arguments += $ExtraArgument }

        $process = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList $arguments -PassThru -Wait `
            -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
        $output = (Get-Content -LiteralPath $outputPath -Raw -ErrorAction SilentlyContinue) +
            (Get-Content -LiteralPath $errorPath -Raw -ErrorAction SilentlyContinue)
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
    }
}

AfterAll {
    if ($script:tempDirectory -and (Test-Path -LiteralPath $script:tempDirectory)) {
        Remove-Item -LiteralPath $script:tempDirectory -Recurse -Force
    }
}

Describe 'Install-RdsSqlServerCa.ps1' {
    It 'accepts the exact AWS thumbprint and WhatIf does not install a certificate' {
        $result = Invoke-InstallerProcess -VerifiedThumbprint $script:thumbprint

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'What if:'
        $result.Output | Should -Match 'No certificate was installed'
        Get-ChildItem Cert:\CurrentUser\Root |
            Where-Object Thumbprint -EQ $script:thumbprint | Should -BeNullOrEmpty
    }

    It 'rejects a thumbprint that does not match the selected root' {
        $result = Invoke-InstallerProcess -VerifiedThumbprint ('0' * 40)

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'does not match the independently verified AWS thumbprint'
    }

    It 'rejects a PEM file when the Windows PKCS#7 bundle is required' {
        $pemPath = Join-Path $script:tempDirectory 'invalid.pem'
        [System.IO.File]::WriteAllText($pemPath, 'not a PKCS7 certificate')
        $savedBundlePath = $script:bundlePath
        $script:bundlePath = $pemPath
        try {
            $result = Invoke-InstallerProcess -VerifiedThumbprint $script:thumbprint
        }
        finally {
            $script:bundlePath = $savedBundlePath
        }

        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Use the AWS .p7b file'
    }
}
