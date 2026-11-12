BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-RdsSqlServerPrerequisites.ps1'
    . $scriptPath
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
