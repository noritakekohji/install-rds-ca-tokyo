#Requires -Version 5.1
<#
.SYNOPSIS
Runs the customer RDS readiness check, installs the configured root CA only when missing, and checks again.
.DESCRIPTION
Writes detailed child-script output to a unique text log beside this script. Console output contains only concise
status messages and the log path. The same-folder .env is retained after a run for the user to manage. The log
never includes values read from .env, but may contain endpoint and IP information.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Customer-facing console status messages are intentionally concise.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Initialize-RdsCustomerLogFile {
    param([Parameter(Mandatory)][string]$Directory)

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $uniqueId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $candidate = Join-Path $Directory "RdsSqlServerCheck-$stamp-$uniqueId.log"
    $stream = [System.IO.File]::Open(
        $candidate,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )
    $stream.Dispose()
    return $candidate
}

function Add-RdsCustomerLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )

    [System.IO.File]::AppendAllText(
        $Path,
        $Message + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Protect-RdsCustomerOutput {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SensitiveValues
    )

    foreach ($line in $Lines) {
        $safeLine = [string]$line
        foreach ($sensitiveValue in $SensitiveValues) {
            if (-not [string]::IsNullOrEmpty($sensitiveValue)) {
                $safeLine = $safeLine.Replace($sensitiveValue, '[REDACTED]')
            }
        }
        Write-Output $safeLine
    }
}

function Get-RdsCustomerSensitiveValue {
    param([Parameter(Mandatory)][string]$EnvironmentPath)

    $values = @()
    foreach ($line in [System.IO.File]::ReadAllLines($EnvironmentPath)) {
        if ($line -match '^\s*SQL_PASSWORD\s*=\s*(?<value>.*)\s*$') {
            $value = $Matches.value.Trim()
            if ($value.Length -ge 2 -and
                (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                 ($value.StartsWith("'") -and $value.EndsWith("'")))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            if (-not [string]::IsNullOrEmpty($value)) { $values += $value }
        }
    }
    return ,$values
}

function Invoke-RdsCustomerPowerShellFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AutoConfirm
    )

    $escapedPath = $Path.Replace("'", "''")
    $capturePath = Join-Path ([System.IO.Path]::GetTempPath()) ('RdsSqlServerCheck-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $escapedCapturePath = $capturePath.Replace("'", "''")
    $command = "& '$escapedPath'"
    if ($AutoConfirm) { $command += ' -Confirm:$false' }
    $command += " *> '$escapedCapturePath'"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    try {
        $processOutput = @(& $powershellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedCommand 2>&1)
        $exitCode = $LASTEXITCODE
        $capturedOutput = @()
        if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
            $capturedText = [System.IO.File]::ReadAllText($capturePath)
            if (-not [string]::IsNullOrEmpty($capturedText)) {
                $capturedOutput = @($capturedText -split '\r?\n' | Where-Object { $_ -ne '' })
            }
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = @($capturedOutput + @($processOutput | ForEach-Object { [string]$_ }))
        }
    }
    finally {
        if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
            Remove-Item -LiteralPath $capturePath -Force -ErrorAction Stop
        }
    }
}

function Get-RdsCustomerCheckDecision {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Output
    )

    if ($ExitCode -eq 0) { return 'Success' }
    if (($Output -join [Environment]::NewLine) -match '(?m)^\[FAIL\]\s+RDS root CA trust:') {
        return 'InstallCertificate'
    }
    return 'OtherFailure'
}

function Add-RdsCustomerOutputToLog {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SensitiveValues,
        [Parameter(Mandatory)][string]$LogPath
    )

    Protect-RdsCustomerOutput -Lines $Lines -SensitiveValues $SensitiveValues |
        ForEach-Object { Add-RdsCustomerLog -Path $LogPath -Message $_ }
}

function Invoke-RdsCustomerDiagnostic {
    param(
        [Parameter(Mandatory)][string]$CheckerPath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SensitiveValues,
        [Parameter(Mandatory)][string]$StageName,
        [Parameter(Mandatory)][string]$ProgressMessage
    )

    Write-Host $ProgressMessage
    Add-RdsCustomerLog -Path $LogPath -Message "=== $StageName ==="
    $result = Invoke-RdsCustomerPowerShellFile -Path $CheckerPath
    Add-RdsCustomerOutputToLog -Lines $result.Output -SensitiveValues $SensitiveValues -LogPath $LogPath
    return $result
}

function Invoke-RdsCustomerCertificateInstall {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SensitiveValues
    )

    $bundlePaths = @(
        (Join-Path $Directory 'global-bundle.p7b'),
        (Join-Path $Directory 'global-bundle.pem')
    )
    if (-not ($bundlePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })) {
        Add-RdsCustomerLog -Path $LogPath -Message 'ERROR: Expected root CA is missing and no default AWS bundle is beside the scripts.'
        Write-Host '[NG] 証明書バンドルが見つかりません。配布担当者にご確認ください。'
        return $false
    }

    $answer = Read-Host '[確認] 設定済みのAWS RDSルートCAをCurrentUser\Rootに追加します。続行しますか? (Y/N)'
    if ($answer -notmatch '^[Yy]$') {
        Add-RdsCustomerLog -Path $LogPath -Message 'Certificate installation was declined by the user.'
        Write-Host '[INFO] 証明書の導入をキャンセルしました。'
        return $false
    }

    Write-Host '[2/3] 対象CAが未導入のため、現在のユーザーに導入しています...'
    Add-RdsCustomerLog -Path $LogPath -Message '=== Install configured root CA for CurrentUser ==='
    $result = Invoke-RdsCustomerPowerShellFile -Path $InstallerPath -AutoConfirm
    Add-RdsCustomerOutputToLog -Lines $result.Output -SensitiveValues $SensitiveValues -LogPath $LogPath
    if ($result.ExitCode -ne 0) {
        Add-RdsCustomerLog -Path $LogPath -Message "Installer exit code: $($result.ExitCode)"
        Write-Host '[NG] 証明書を導入できませんでした。ログをご確認ください。'
        return $false
    }
    return $true
}

function Invoke-RdsCustomerReadinessFlow {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SensitiveValues
    )

    $checkerPath = Join-Path $Directory 'Test-RdsSqlServerPrerequisites.ps1'
    $installerPath = Join-Path $Directory 'Install-RdsSqlServerCa.ps1'
    if (-not (Test-Path -LiteralPath $checkerPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        Add-RdsCustomerLog -Path $LogPath -Message 'ERROR: Required checker or installer script is missing.'
        Write-Host '[NG] 必要なスクリプトが見つかりません。配布フォルダー一式を確認してください。'
        return [pscustomobject]@{ ExitCode = 1; SuccessMessage = $null }
    }

    $initialCheck = Invoke-RdsCustomerDiagnostic `
        -CheckerPath $checkerPath `
        -LogPath $LogPath `
        -SensitiveValues $SensitiveValues `
        -StageName 'Initial connection check' `
        -ProgressMessage '[1/3] 証明書とSQL接続を確認しています...'
    $decision = Get-RdsCustomerCheckDecision -ExitCode $initialCheck.ExitCode -Output $initialCheck.Output
    if ($decision -eq 'Success') {
        return [pscustomobject]@{
            ExitCode = 0
            SuccessMessage = '[OK] 証明書とSQL接続の診断でNGはありません。'
        }
    }
    if ($decision -eq 'OtherFailure') {
        Add-RdsCustomerLog -Path $LogPath -Message 'Stopped: Initial check failed for a reason other than a missing expected root CA.'
        Write-Host '[NG] 接続診断で問題が見つかりました。証明書以外の原因も含めログをご確認ください。'
        return [pscustomobject]@{ ExitCode = 1; SuccessMessage = $null }
    }

    if (-not (Invoke-RdsCustomerCertificateInstall `
        -Directory $Directory `
        -InstallerPath $installerPath `
        -LogPath $LogPath `
        -SensitiveValues $SensitiveValues)) {
        return [pscustomobject]@{ ExitCode = 1; SuccessMessage = $null }
    }

    $finalCheck = Invoke-RdsCustomerDiagnostic `
        -CheckerPath $checkerPath `
        -LogPath $LogPath `
        -SensitiveValues $SensitiveValues `
        -StageName 'Connection check after installation' `
        -ProgressMessage '[3/3] 導入後の接続を再確認しています...'
    if ($finalCheck.ExitCode -eq 0) {
        return [pscustomobject]@{
            ExitCode = 0
            SuccessMessage = '[OK] 証明書を導入し、SQL接続の診断も成功しました。'
        }
    }

    Add-RdsCustomerLog -Path $LogPath -Message "Final diagnostic exit code: $($finalCheck.ExitCode)"
    Write-Host '[NG] 証明書導入後の接続診断に失敗しました。ログをご確認ください。'
    return [pscustomobject]@{ ExitCode = 1; SuccessMessage = $null }
}

function Write-RdsCustomerError {
    param(
        [AllowNull()][string]$LogPath,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SensitiveValues
    )

    if ($LogPath) {
        $safeMessage = $Message
        foreach ($sensitiveValue in $SensitiveValues) {
            if (-not [string]::IsNullOrEmpty($sensitiveValue)) {
                $safeMessage = $safeMessage.Replace($sensitiveValue, '[REDACTED]')
            }
        }
        try {
            Add-RdsCustomerLog -Path $LogPath -Message ('ERROR: ' + $safeMessage)
        }
        catch {
            Write-Host '[NG] 詳細ログへエラー内容を記録できませんでした。'
        }
        Write-Host '[NG] ツールの実行中にエラーが発生しました。ログをご確認ください。'
    }
    else {
        Write-Host '[NG] ログを作成できません。フォルダーの書き込み権限を確認してください。'
    }
}

function Complete-RdsSqlServerCustomerFlow {
    param(
        [AllowNull()][string]$LogPath,
        [Parameter(Mandatory)][psobject]$Result
    )

    if ($LogPath) {
        try {
            Add-RdsCustomerLog -Path $LogPath -Message ('Finished: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
        }
        catch {
            Write-Host '[NG] 完了情報を詳細ログへ記録できませんでした。'
            $Result.ExitCode = 1
            $Result.SuccessMessage = $null
        }
        Write-Host "詳細ログ: $LogPath"
        Write-Host 'ログには接続先やIPアドレスが含まれる場合があります。共有前にご確認ください。'
    }

    return $Result
}

function Invoke-RdsSqlServerCustomerFlow {
    param([Parameter(Mandatory)][string]$Directory)

    $logPath = $null
    $envPath = Join-Path $Directory '.env'
    $sensitiveValues = @()
    $result = [pscustomobject]@{ ExitCode = 1; SuccessMessage = $null }

    try {
        $logPath = Initialize-RdsCustomerLogFile -Directory $Directory
        Add-RdsCustomerLog -Path $logPath -Message ('Started: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
        Add-RdsCustomerLog -Path $logPath -Message 'Detailed diagnostic output follows. Password values from .env are redacted.'
        if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
            Add-RdsCustomerLog -Path $logPath -Message 'ERROR: Same-folder .env file is missing.'
            Write-Host '[NG] 接続設定(.env)が見つかりません。配布担当者にご確認ください。'
        }
        else {
            $sensitiveValues = @(Get-RdsCustomerSensitiveValue -EnvironmentPath $envPath)
            $result = Invoke-RdsCustomerReadinessFlow `
                -Directory $Directory `
                -LogPath $logPath `
                -SensitiveValues $sensitiveValues
        }
    }
    catch {
        Write-RdsCustomerError -LogPath $logPath -Message $_.Exception.Message -SensitiveValues $sensitiveValues
        $result.ExitCode = 1
        $result.SuccessMessage = $null
    }

    $result = Complete-RdsSqlServerCustomerFlow `
        -LogPath $logPath `
        -Result $result
    if ($result.ExitCode -eq 0 -and $result.SuccessMessage) { Write-Host $result.SuccessMessage }
    return [pscustomobject]@{ ExitCode = $result.ExitCode; LogPath = $logPath }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RdsSqlServerCustomerFlow -Directory $PSScriptRoot
    exit $result.ExitCode
}
