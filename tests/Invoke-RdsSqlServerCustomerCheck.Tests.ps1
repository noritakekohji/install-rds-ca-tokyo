BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-RdsSqlServerCustomerCheck.ps1'
    . $scriptPath
    $script:testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:testDirectory | Out-Null
}

AfterAll {
    if (Test-Path -LiteralPath $script:testDirectory) {
        Remove-Item -LiteralPath $script:testDirectory -Recurse -Force
    }
}

Describe 'Get-RdsCustomerCheckDecision' {
    It 'accepts an initial diagnostic with no failures' {
        Get-RdsCustomerCheckDecision -ExitCode 0 -Output @('[PASS] TLS certificate validation') | Should -Be 'Success'
    }

    It 'requests installation only when the expected root CA check failed' {
        Get-RdsCustomerCheckDecision -ExitCode 1 -Output @('[FAIL] RDS root CA trust: missing') | Should -Be 'InstallCertificate'
        Get-RdsCustomerCheckDecision -ExitCode 1 -Output @('[FAIL] SQL login: rejected') | Should -Be 'OtherFailure'
    }
}

Describe 'Protect-RdsCustomerOutput' {
    It 'redacts the configured plaintext password from child output' {
        $result = @(Protect-RdsCustomerOutput -Lines @('Failure mentions test-password') -SensitiveValues @('test-password'))

        $result | Should -Be @('Failure mentions [REDACTED]')
    }
}

Describe 'Run-RdsSqlServerCheck.bat encoding' {
    It 'uses ASCII and Windows CRLF line endings for cmd.exe compatibility' {
        $batchPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Run-RdsSqlServerCheck.bat'
        $bytes = [System.IO.File]::ReadAllBytes($batchPath)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)

        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text -match '(?<!\r)\n' | Should -BeFalse
        $text -match '\r\n' | Should -BeTrue
    }
}

Describe 'Invoke-RdsCustomerPowerShellFile' {
    It 'captures child PowerShell host output and preserves its exit code' {
        $childPath = Join-Path $script:testDirectory 'child-output.ps1'
        [System.IO.File]::WriteAllText($childPath, "Write-Host '[FAIL] child marker'`r`nexit 1")

        $result = Invoke-RdsCustomerPowerShellFile -Path $childPath

        $result.ExitCode | Should -Be 1
        ($result.Output -join [Environment]::NewLine) | Should -Match '\[FAIL\] child marker'
    }
}

Describe 'Invoke-RdsSqlServerCustomerFlow' {
    BeforeEach {
        Get-ChildItem -LiteralPath $script:testDirectory -Force | Remove-Item -Recurse -Force
        [System.IO.File]::WriteAllText((Join-Path $script:testDirectory '.env'), 'SQL_PASSWORD="test-password"')
        [System.IO.File]::WriteAllText((Join-Path $script:testDirectory 'Test-RdsSqlServerPrerequisites.ps1'), '# test stub')
        [System.IO.File]::WriteAllText((Join-Path $script:testDirectory 'Install-RdsSqlServerCa.ps1'), '# test stub')
    }

    It 'does not run the installer when the initial connection check succeeds' {
        Mock Invoke-RdsCustomerPowerShellFile {
            [pscustomobject]@{ ExitCode = 0; Output = @('[PASS] All checks') }
        }

        $result = Invoke-RdsSqlServerCustomerFlow -Directory $script:testDirectory

        $result.ExitCode | Should -Be 0
        Should -Invoke Invoke-RdsCustomerPowerShellFile -Times 1 -Exactly -ParameterFilter { -not $AutoConfirm }
        Should -Invoke Invoke-RdsCustomerPowerShellFile -Times 0 -ParameterFilter { $AutoConfirm }
        Test-Path -LiteralPath (Join-Path $script:testDirectory '.env') | Should -BeTrue
        Test-Path -LiteralPath $result.LogPath | Should -BeTrue
    }

    It 'installs the root CA and reruns the diagnostic only when the CA is missing' {
        New-Item -ItemType File -Path (Join-Path $script:testDirectory 'global-bundle.pem') | Out-Null
        Mock Read-Host { 'Y' }
        Mock Invoke-RdsCustomerPowerShellFile {
            if ($AutoConfirm) {
                [pscustomobject]@{ ExitCode = 0; Output = @('SUCCESS: Verified root CA installed.') }
            }
            elseif (-not (Test-Path -LiteralPath (Join-Path $script:testDirectory 'first-check-complete'))) {
                New-Item -ItemType File -Path (Join-Path $script:testDirectory 'first-check-complete') | Out-Null
                [pscustomobject]@{ ExitCode = 1; Output = @('[FAIL] RDS root CA trust: missing') }
            }
            else {
                [pscustomobject]@{ ExitCode = 0; Output = @('[PASS] SQL connection') }
            }
        }

        $result = Invoke-RdsSqlServerCustomerFlow -Directory $script:testDirectory

        $result.ExitCode | Should -Be 0
        Should -Invoke Invoke-RdsCustomerPowerShellFile -Times 2 -Exactly -ParameterFilter { -not $AutoConfirm }
        Should -Invoke Invoke-RdsCustomerPowerShellFile -Times 1 -Exactly -ParameterFilter { $AutoConfirm }
        Test-Path -LiteralPath (Join-Path $script:testDirectory '.env') | Should -BeTrue
    }

    It 'does not install a certificate for a non-certificate diagnostic failure' {
        Mock Invoke-RdsCustomerPowerShellFile {
            [pscustomobject]@{ ExitCode = 1; Output = @('Database error contained test-password') }
        }

        $result = Invoke-RdsSqlServerCustomerFlow -Directory $script:testDirectory

        $result.ExitCode | Should -Be 1
        Should -Invoke Invoke-RdsCustomerPowerShellFile -Times 1 -Exactly -ParameterFilter { -not $AutoConfirm }
        Should -Invoke Invoke-RdsCustomerPowerShellFile -Times 0 -ParameterFilter { $AutoConfirm }
        Test-Path -LiteralPath (Join-Path $script:testDirectory '.env') | Should -BeTrue
        $logText = [System.IO.File]::ReadAllText($result.LogPath)
        $logText | Should -Not -Match 'test-password'
        $logText | Should -Match '\[REDACTED\]'
    }
}
