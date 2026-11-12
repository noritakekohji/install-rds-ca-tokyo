BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-RdsSqlServerPrerequisites.ps1'
    . $scriptPath
    $script:tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tempDirectory | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:tempDirectory) {
        Remove-Item -LiteralPath $script:tempDirectory -Recurse -Force
    }
}

Describe 'Invoke-RdsPrerequisiteCheck' {
    BeforeEach {
        Mock Get-RdsRootStoreCertificate {
            [pscustomobject]@{
                Store = 'Cert:\CurrentUser\Root'
                Subject = 'CN=Amazon RDS ap-northeast-1 Root CA RSA2048 G1'
                Thumbprint = ('A' * 40)
                NotAfter = [DateTime]::UtcNow.AddYears(1)
                IsCurrentlyValid = $true
            }
        }
        Mock Resolve-RdsEndpoint {
            ,([System.Net.IPAddress]::Parse('192.0.2.10'))
        }
        Mock Test-RdsTcpPort {
            [pscustomobject]@{ Succeeded = $true; Message = 'TCP connection succeeded.' }
        }
    }

    It 'reports certificate, DNS, and TCP checks independently without changing the machine' {
        $results = Invoke-RdsPrerequisiteCheck -HostName 'example.rds.amazonaws.com' -TcpPort 1433 -Thumbprint ('A' * 40) -TimeoutMilliseconds 5000

        $results.Count | Should -Be 3
        @($results | Where-Object { -not $_.Passed }).Count | Should -Be 0
        Should -Invoke Get-RdsRootStoreCertificate -Times 1
        Should -Invoke Resolve-RdsEndpoint -Times 1
        Should -Invoke Test-RdsTcpPort -Times 1
    }

    It 'reports a missing trusted root while still checking DNS and TCP' {
        Mock Get-RdsRootStoreCertificate { @() }

        $results = Invoke-RdsPrerequisiteCheck -HostName 'example.rds.amazonaws.com' -TcpPort 1433 -Thumbprint ('A' * 40) -TimeoutMilliseconds 5000

        $results[0].Passed | Should -BeFalse
        $results[1].Passed | Should -BeTrue
        $results[2].Passed | Should -BeTrue
    }

    It 'does not treat an expired matching root as trusted' {
        Mock Get-RdsRootStoreCertificate {
            [pscustomobject]@{
                Store = 'Cert:\CurrentUser\Root'
                Subject = 'CN=Amazon RDS ap-northeast-1 Root CA RSA2048 G1'
                Thumbprint = ('A' * 40)
                NotAfter = [DateTime]::UtcNow.AddDays(-1)
                IsCurrentlyValid = $false
            }
        }

        $results = Invoke-RdsPrerequisiteCheck -HostName 'example.rds.amazonaws.com' -TcpPort 1433 -Thumbprint ('A' * 40) -TimeoutMilliseconds 5000

        $results[0].Passed | Should -BeFalse
        $results[0].Detail | Should -Be 'Matching root CA is installed but outside its validity period.'
    }

    It 'skips TCP when DNS lookup fails' {
        Mock Resolve-RdsEndpoint { throw 'DNS unavailable' }

        $results = Invoke-RdsPrerequisiteCheck -HostName 'missing.example' -TcpPort 1433 -Thumbprint ('A' * 40) -TimeoutMilliseconds 5000

        $results[1].Passed | Should -BeFalse
        $results[2].Detail | Should -Be 'Skipped because DNS resolution failed.'
        Should -Invoke Test-RdsTcpPort -Times 0
    }

    It 'reports a closed or unreachable TCP port as a failure' {
        Mock Test-RdsTcpPort {
            [pscustomobject]@{ Succeeded = $false; Message = 'Connection refused.' }
        }

        $results = Invoke-RdsPrerequisiteCheck -HostName 'example.rds.amazonaws.com' -TcpPort 1433 -Thumbprint ('A' * 40) -TimeoutMilliseconds 5000

        $results[2].Passed | Should -BeFalse
        $results[2].Detail | Should -Be 'Connection refused.'
    }
}

Describe 'Import-RdsConnectionEnvironment' {
    It 'reads the same-folder values without changing the plaintext .env file' {
        $password = 'test-' + [Guid]::NewGuid().ToString('N') + '#=end'
        $envPath = Join-Path $script:tempDirectory 'valid.env'
        $lines = @(
            'RDS_ENDPOINT=db.example.ap-northeast-1.rds.amazonaws.com'
            'RDS_PORT=1444'
            'RDS_DATABASE=analytics'
            'SQL_USERNAME=diagnostic_user'
            ('SQL_PASSWORD="' + $password + '"')
        )
        $content = $lines -join [Environment]::NewLine
        [System.IO.File]::WriteAllText($envPath, $content, [System.Text.Encoding]::UTF8)

        $configuration = Import-RdsConnectionEnvironment -Path $envPath

        $configuration.ServerName | Should -Be 'db.example.ap-northeast-1.rds.amazonaws.com'
        $configuration.Port | Should -Be 1444
        $configuration.Database | Should -Be 'analytics'
        [System.IO.File]::ReadAllText($envPath) | Should -Be $content
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($configuration.SecurePassword)
        try {
            [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer) | Should -Be $password
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        }
    }

    It 'uses port 1433 when RDS_PORT is omitted' {
        $envPath = Join-Path $script:tempDirectory 'default-port.env'
        $lines = @(
            'RDS_ENDPOINT=db.example.ap-northeast-1.rds.amazonaws.com'
            'RDS_DATABASE=analytics'
            'SQL_USERNAME=diagnostic_user'
            ('SQL_PASSWORD=' + [Guid]::NewGuid().ToString('N'))
        )
        [System.IO.File]::WriteAllText($envPath, ($lines -join [Environment]::NewLine), [System.Text.Encoding]::UTF8)

        (Import-RdsConnectionEnvironment -Path $envPath).Port | Should -Be 1433
    }

    It 'rejects an IP literal because the TLS certificate is checked against the RDS hostname' {
        $envPath = Join-Path $script:tempDirectory 'ip-endpoint.env'
        $lines = @(
            'RDS_ENDPOINT=192.0.2.10'
            'RDS_DATABASE=analytics'
            'SQL_USERNAME=diagnostic_user'
            ('SQL_PASSWORD=' + [Guid]::NewGuid().ToString('N'))
        )
        [System.IO.File]::WriteAllText($envPath, ($lines -join [Environment]::NewLine), [System.Text.Encoding]::UTF8)

        { Import-RdsConnectionEnvironment -Path $envPath } | Should -Throw '*Use the RDS endpoint DNS name*'
    }

    It 'rejects duplicate or unsupported setting names' {
        $envPath = Join-Path $script:tempDirectory 'duplicate.env'
        $lines = @(
            'RDS_ENDPOINT=db.example.ap-northeast-1.rds.amazonaws.com'
            'RDS_ENDPOINT=other.example.ap-northeast-1.rds.amazonaws.com'
            'RDS_DATABASE=analytics'
            'SQL_USERNAME=diagnostic_user'
            ('SQL_PASSWORD=' + [Guid]::NewGuid().ToString('N'))
        )
        [System.IO.File]::WriteAllText($envPath, ($lines -join [Environment]::NewLine), [System.Text.Encoding]::UTF8)

        { Import-RdsConnectionEnvironment -Path $envPath } | Should -Throw '*duplicate setting*'
    }
}

Describe 'Get-RdsSqlConnection' {
    It 'requires encryption and certificate validation without putting credentials in the connection string' {
        $password = ConvertTo-SecureString -String ('test-' + [Guid]::NewGuid().ToString('N')) -AsPlainText -Force
        $configuration = [pscustomobject]@{
            ServerName = 'db.example.ap-northeast-1.rds.amazonaws.com'
            Port = 1433
            Database = 'analytics'
            Username = 'diagnostic_user'
            SecurePassword = $password
        }
        $connection = Get-RdsSqlConnection -Configuration $configuration -TimeoutSeconds 8
        try {
            $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($connection.ConnectionString)
            $builder.Encrypt | Should -BeTrue
            $builder.TrustServerCertificate | Should -BeFalse
            $builder.DataSource | Should -Be 'tcp:db.example.ap-northeast-1.rds.amazonaws.com,1433'
            $builder.InitialCatalog | Should -Be 'analytics'
            $builder.UserID | Should -BeNullOrEmpty
            $builder.Password | Should -BeNullOrEmpty
        }
        finally {
            $connection.Dispose()
        }
    }
}

Describe 'Invoke-RdsConnectionReadinessCheck' {
    BeforeEach {
        Mock Invoke-RdsPrerequisiteCheck {
            @(
                [pscustomobject]@{ Check = 'RDS root CA trust'; Passed = $true; Detail = 'CA present.' }
                [pscustomobject]@{ Check = 'DNS name resolution'; Passed = $true; Detail = 'IP resolved.' }
                [pscustomobject]@{ Check = "TCP $($Configuration.Port)"; Passed = $true; Detail = 'TCP opened.' }
            )
        }
        Mock Test-RdsSqlConnection {
            [pscustomobject]@{
                TlsValidated = $true
                LoginSucceeded = $true
                DatabaseAccessible = $true
                DatabaseName = 'analytics'
                EncryptOption = 'TRUE'
                EncryptionDetail = 'Server reports encrypt_option=TRUE.'
                ErrorMessage = $null
            }
        }
        $script:connectionConfiguration = [pscustomobject]@{
            ServerName = 'db.example.ap-northeast-1.rds.amazonaws.com'
            Port = 1433
            Database = 'analytics'
            Username = 'diagnostic_user'
            SecurePassword = (ConvertTo-SecureString -String ([Guid]::NewGuid().ToString('N')) -AsPlainText -Force)
        }
    }

    It 'reports TLS, login, database, and encryption checks independently' {
        $results = Invoke-RdsConnectionReadinessCheck -Configuration $script:connectionConfiguration -Thumbprint ('A' * 40) -TcpTimeout 5000 -SqlTimeout 8

        $results.Count | Should -Be 7
        @($results | Where-Object { $_.Passed -eq $false }).Count | Should -Be 0
        Should -Invoke Test-RdsSqlConnection -Times 1
    }

    It 'marks network-dependent checks as skipped when TCP fails' {
        Mock Invoke-RdsPrerequisiteCheck {
            @(
                [pscustomobject]@{ Check = 'RDS root CA trust'; Passed = $true; Detail = 'CA present.' }
                [pscustomobject]@{ Check = 'DNS name resolution'; Passed = $true; Detail = 'IP resolved.' }
                [pscustomobject]@{ Check = 'TCP 1433'; Passed = $false; Detail = 'Timeout.' }
            )
        }

        $results = Invoke-RdsConnectionReadinessCheck -Configuration $script:connectionConfiguration -Thumbprint ('A' * 40) -TcpTimeout 5000 -SqlTimeout 8

        $results.Count | Should -Be 7
        $results[3].Passed | Should -BeNullOrEmpty
        $results[3].Detail | Should -Match 'Skipped'
        Should -Invoke Test-RdsSqlConnection -Times 0
    }

    It 'reports TLS validation separately when SQL authentication fails' {
        Mock Test-RdsSqlConnection {
            [pscustomobject]@{
                TlsValidated = $true
                LoginSucceeded = $false
                DatabaseAccessible = $null
                DatabaseName = 'analytics'
                EncryptOption = $null
                EncryptionDetail = $null
                ErrorMessage = 'SQL login was rejected.'
            }
        }

        $results = Invoke-RdsConnectionReadinessCheck -Configuration $script:connectionConfiguration -Thumbprint ('A' * 40) -TcpTimeout 5000 -SqlTimeout 8

        $results[3].Passed | Should -BeTrue
        $results[4].Passed | Should -BeFalse
    }
}
