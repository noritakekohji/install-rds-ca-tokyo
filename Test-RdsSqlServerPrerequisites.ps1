#Requires -Version 5.1
<#
.SYNOPSIS
Checks the client certificate, network path, TLS validation, SQL login, and database access for Amazon RDS for SQL Server.
.DESCRIPTION
Reads the temporary .env file beside this script. The .env stores the SQL
password in plaintext as requested; this script only reads it and never creates,
copies, or retains a connection configuration elsewhere.
Then checks the trust store, DNS, TCP, TLS certificate validation, SQL login,
database access, and server encryption status when available.
.NOTES
No server or certificate-store settings are changed. SQL credentials are never printed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive diagnostic output is the customer-facing result.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The password is explicitly stored in the local .env by user request; SqlCredential requires a SecureString for the in-memory connection.')]
[CmdletBinding()]
param()

# Keep these values aligned with the installer configuration and the target RDS CA.
$ExpectedRootThumbprint = 'D790BBB661BAFA4101829F103D639BEFA300F9A4'
$TcpTimeoutMilliseconds = 5000
$SqlConnectTimeoutSeconds = 8
$ConnectionConfigPath = Join-Path $PSScriptRoot '.env'

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-RdsEndpointHostname {
    param([Parameter(Mandatory)][string]$HostName)

    $normalizedHostName = $HostName.Trim()
    if ([string]::IsNullOrWhiteSpace($normalizedHostName)) {
        throw 'The RDS endpoint is empty. Use the endpoint DNS name shown in the AWS console.'
    }
    $parsedAddress = $null
    if ([System.Net.IPAddress]::TryParse($normalizedHostName, [ref]$parsedAddress)) {
        throw 'Use the RDS endpoint DNS name, not its IP address. TLS validation checks the endpoint hostname.'
    }
    return $normalizedHostName
}

function Import-RdsConnectionEnvironment {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "A same-folder .env file is required. Create it at '$Path' using .env.example as a guide."
    }

    $allowedNames = @('RDS_ENDPOINT', 'RDS_PORT', 'RDS_DATABASE', 'SQL_USERNAME', 'SQL_PASSWORD')
    $settings = @{}
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        $trimmedLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) { continue }
        if ($line -notmatch '^\s*(?<name>[A-Z][A-Z0-9_]*)\s*=\s*(?<value>.*)\s*$') {
            throw ".env line $lineNumber must use NAME=value syntax."
        }

        $name = $Matches.name
        if ($allowedNames -notcontains $name) { throw ".env line $lineNumber has unsupported setting '$name'." }
        if ($settings.ContainsKey($name)) { throw ".env contains duplicate setting '$name'." }
        $value = $Matches.value.Trim()
        if ($value.StartsWith('"') -or $value.StartsWith("'")) {
            $quote = $value.Substring(0, 1)
            if ($value.Length -lt 2 -or -not $value.EndsWith($quote)) {
                throw ".env line $lineNumber has an unmatched quote."
            }
            $value = $value.Substring(1, $value.Length - 2)
        }
        $settings[$name] = $value
    }

    foreach ($name in @('RDS_ENDPOINT', 'RDS_DATABASE', 'SQL_USERNAME', 'SQL_PASSWORD')) {
        if (-not $settings.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$settings[$name])) {
            throw ".env is missing required setting '$name'."
        }
    }

    $hostName = Assert-RdsEndpointHostname -HostName $settings.RDS_ENDPOINT
    $tcpPort = 1433
    if ($settings.ContainsKey('RDS_PORT') -and -not [string]::IsNullOrWhiteSpace([string]$settings.RDS_PORT)) {
        if (-not [int]::TryParse([string]$settings.RDS_PORT, [ref]$tcpPort) -or $tcpPort -lt 1 -or $tcpPort -gt 65535) {
            throw 'RDS_PORT must be an integer from 1 through 65535.'
        }
    }

    $securePassword = ConvertTo-SecureString -String ([string]$settings.SQL_PASSWORD) -AsPlainText -Force
    [void]$settings.Remove('SQL_PASSWORD')
    return [pscustomobject]@{
        ServerName = $hostName
        Port = $tcpPort
        Database = ([string]$settings.RDS_DATABASE).Trim()
        Username = ([string]$settings.SQL_USERNAME).Trim()
        SecurePassword = $securePassword
    }
}

function Get-RdsRootStoreCertificate {
    param([Parameter(Mandatory)][string]$Thumbprint)

    foreach ($storePath in @('Cert:\CurrentUser\Root', 'Cert:\LocalMachine\Root')) {
        $matchingCertificates = Get-ChildItem -LiteralPath $storePath |
            Where-Object { $_.Thumbprint -eq $Thumbprint }
        foreach ($certificate in $matchingCertificates) {
            $now = [DateTime]::UtcNow
            $isCurrentlyValid = $now -ge $certificate.NotBefore.ToUniversalTime() -and
                $now -le $certificate.NotAfter.ToUniversalTime()
            [pscustomobject]@{
                Store            = $storePath
                Subject          = $certificate.Subject
                Thumbprint       = $certificate.Thumbprint
                NotAfter         = $certificate.NotAfter
                IsCurrentlyValid = $isCurrentlyValid
            }
        }
    }
}

function Resolve-RdsEndpoint {
    param([Parameter(Mandatory)][string]$HostName)

    try {
        return [System.Net.Dns]::GetHostAddresses($HostName)
    }
    catch {
        throw "DNS lookup failed for '$HostName': $($_.Exception.Message)"
    }
}

function Test-RdsTcpPort {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$TcpPort,
        [Parameter(Mandatory)][ValidateRange(1, 60000)][int]$TimeoutMilliseconds
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $asyncResult = $client.BeginConnect($HostName, $TcpPort, $null, $null)
        $waitHandle = $asyncResult.AsyncWaitHandle
        if (-not $waitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return [pscustomobject]@{ Succeeded = $false; Message = "Timed out after $TimeoutMilliseconds ms." }
        }
        $client.EndConnect($asyncResult)
        return [pscustomobject]@{ Succeeded = $true; Message = 'TCP connection succeeded.' }
    }
    catch {
        return [pscustomobject]@{ Succeeded = $false; Message = $_.Exception.Message }
    }
    finally {
        if ($waitHandle) { $waitHandle.Close() }
        $client.Close()
    }
}

function Get-RdsSqlConnection {
    param([Parameter(Mandatory)][psobject]$Configuration, [Parameter(Mandatory)][ValidateRange(1, 60)][int]$TimeoutSeconds)

    $password = $Configuration.SecurePassword
    if (-not $password.IsReadOnly()) { $password.MakeReadOnly() }
    $credential = [System.Data.SqlClient.SqlCredential]::new($Configuration.Username, $password)
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = 'tcp:{0},{1}' -f $Configuration.ServerName, $Configuration.Port
    $builder['Initial Catalog'] = $Configuration.Database
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $false
    $builder['Connect Timeout'] = $TimeoutSeconds
    $builder['Persist Security Info'] = $false
    $builder['Pooling'] = $false
    return [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString, $credential)
}

function Test-RdsSqlConnection {
    param([Parameter(Mandatory)][psobject]$Configuration, [Parameter(Mandatory)][ValidateRange(1, 60)][int]$TimeoutSeconds)

    $connection = $null
    $isOpen = $false
    try {
        $connection = Get-RdsSqlConnection -Configuration $Configuration -TimeoutSeconds $TimeoutSeconds
        $connection.Open()
        $isOpen = $true
        $databaseName = $Configuration.Database
        $encryptOption = $null
        $encryptionDetail = 'Client requested Encrypt=True with TrustServerCertificate=False.'
        try {
            $command = $connection.CreateCommand()
            $command.CommandText = 'SELECT DB_NAME(), encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID;'
            $reader = $command.ExecuteReader()
            try {
                if ($reader.Read()) {
                    $databaseName = [string]$reader.GetValue(0)
                    $encryptOption = [string]$reader.GetValue(1)
                    $encryptionDetail = "Server reports encrypt_option=$encryptOption."
                } else {
                    $encryptionDetail = 'Connection succeeded; server encryption status query returned no row.'
                }
            }
            finally {
                $reader.Dispose()
                $command.Dispose()
            }
        }
        catch {
            $encryptionDetail = 'Connection succeeded, but server encryption status could not be queried: ' + $_.Exception.Message
        }
        return [pscustomobject]@{ TlsValidated = $true; LoginSucceeded = $true; DatabaseAccessible = $true; DatabaseName = $databaseName; EncryptOption = $encryptOption; EncryptionDetail = $encryptionDetail; ErrorMessage = $null }
    }
    catch {
        $exception = $_.Exception.GetBaseException()
        $sqlException = $exception -as [System.Data.SqlClient.SqlException]
        $tlsValidated = $null
        $loginSucceeded = $null
        $databaseAccessible = $null
        if ($sqlException -and $sqlException.Number -eq 18456) {
            $tlsValidated = $true
            $loginSucceeded = $false
        } elseif ($sqlException -and $sqlException.Number -eq 4060) {
            $tlsValidated = $true
            $loginSucceeded = $true
            $databaseAccessible = $false
        } elseif ($exception.Message -match '(?i)(certificate|SSL Provider|TLS|secure channel|target principal name|証明書|SSL プロバイダー)') {
            $tlsValidated = $false
        } elseif ($isOpen) {
            $tlsValidated = $true
            $loginSucceeded = $true
            $databaseAccessible = $true
        }
        return [pscustomobject]@{ TlsValidated = $tlsValidated; LoginSucceeded = $loginSucceeded; DatabaseAccessible = $databaseAccessible; DatabaseName = $Configuration.Database; EncryptOption = $null; EncryptionDetail = $null; ErrorMessage = $exception.Message }
    }
    finally {
        if ($connection) { $connection.Dispose() }
    }
}

function Invoke-RdsPrerequisiteCheck {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$TcpPort,
        [Parameter(Mandatory)][string]$Thumbprint,
        [Parameter(Mandatory)][ValidateRange(1, 60000)][int]$TimeoutMilliseconds
    )

    $results = @()
    $trustedRoots = @(Get-RdsRootStoreCertificate -Thumbprint $Thumbprint)
    $validTrustedRoots = @($trustedRoots | Where-Object IsCurrentlyValid)
    $results += [pscustomobject]@{
        Check = 'RDS root CA trust'
        Passed = ($validTrustedRoots.Count -gt 0)
        Detail = if ($validTrustedRoots.Count -gt 0) {
            'Expected, currently valid root CA found in ' + (($validTrustedRoots.Store | Select-Object -Unique) -join ', ')
        } elseif ($trustedRoots.Count -gt 0) {
            'Matching root CA is installed but outside its validity period.'
        } else {
            "Expected root CA ($Thumbprint) was not found in CurrentUser\Root or LocalMachine\Root."
        }
    }

    try {
        $addresses = @(Resolve-RdsEndpoint -HostName $HostName)
        $results += [pscustomobject]@{
            Check = 'DNS name resolution'
            Passed = ($addresses.Count -gt 0)
            Detail = if ($addresses.Count -gt 0) { ($addresses | ForEach-Object { $_.IPAddressToString }) -join ', ' } else { 'No IP addresses returned.' }
        }
    }
    catch {
        $results += [pscustomobject]@{ Check = 'DNS name resolution'; Passed = $false; Detail = $_.Exception.Message }
        $results += [pscustomobject]@{ Check = "TCP $TcpPort"; Passed = $false; Detail = 'Skipped because DNS resolution failed.' }
        return $results
    }

    $tcpResult = Test-RdsTcpPort -HostName $HostName -TcpPort $TcpPort -TimeoutMilliseconds $TimeoutMilliseconds
    $results += [pscustomobject]@{
        Check = "TCP $TcpPort"
        Passed = $tcpResult.Succeeded
        Detail = $tcpResult.Message
    }
    return $results
}

# Dot-sourcing exposes functions for tests without prompting or making network calls.
function Invoke-RdsConnectionReadinessCheck {
    param(
        [Parameter(Mandatory)][psobject]$Configuration,
        [Parameter(Mandatory)][string]$Thumbprint,
        [Parameter(Mandatory)][ValidateRange(1, 60000)][int]$TcpTimeout,
        [Parameter(Mandatory)][ValidateRange(1, 60)][int]$SqlTimeout
    )

    $results = @(Invoke-RdsPrerequisiteCheck -HostName $Configuration.ServerName -TcpPort $Configuration.Port -Thumbprint $Thumbprint -TimeoutMilliseconds $TcpTimeout)
    $networkFailure = @($results | Where-Object { ($_.Check -eq 'DNS name resolution' -or $_.Check -eq "TCP $($Configuration.Port)") -and -not $_.Passed }).Count -gt 0
    if ($networkFailure) {
        foreach ($name in @('TLS certificate validation', 'SQL login', 'Database access', 'Encrypted connection')) {
            $results += [pscustomobject]@{ Check = $name; Passed = $null; Detail = 'Skipped because DNS or TCP connectivity failed.' }
        }
        return $results
    }

    $sqlResult = Test-RdsSqlConnection -Configuration $Configuration -TimeoutSeconds $SqlTimeout
    $results += [pscustomobject]@{
        Check = 'TLS certificate validation'
        Passed = $sqlResult.TlsValidated
            Detail = if ($sqlResult.TlsValidated -eq $true) { 'SQL client accepted the server certificate with TrustServerCertificate=False.' } elseif ($sqlResult.TlsValidated -eq $false) { $sqlResult.ErrorMessage } else { 'TLS validation result is unknown. ' + $sqlResult.ErrorMessage }
    }
    $results += [pscustomobject]@{
        Check = 'SQL login'
        Passed = $sqlResult.LoginSucceeded
        Detail = if ($sqlResult.LoginSucceeded -eq $true) { 'SQL authentication succeeded.' } elseif ($sqlResult.LoginSucceeded -eq $false) { $sqlResult.ErrorMessage } else { 'Not confirmed. ' + $sqlResult.ErrorMessage }
    }
    $results += [pscustomobject]@{
        Check = 'Database access'
        Passed = $sqlResult.DatabaseAccessible
        Detail = if ($sqlResult.DatabaseAccessible -eq $true) { "Connected to database '$($sqlResult.DatabaseName)'." } elseif ($sqlResult.DatabaseAccessible -eq $false) { $sqlResult.ErrorMessage } else { 'Not confirmed.' }
    }
    $encryptionPassed = if ($null -eq $sqlResult.EncryptOption) { $null } else { $sqlResult.EncryptOption -match '^(?i)true$' }
    $results += [pscustomobject]@{ Check = 'Encrypted connection'; Passed = $encryptionPassed; Detail = $sqlResult.EncryptionDetail }
    return $results
}

if ($MyInvocation.InvocationName -ne '.') {
    $configuration = $null
    try {
        $configuration = Import-RdsConnectionEnvironment -Path $ConnectionConfigPath
        Write-Host '=== RDS for SQL Server connection readiness check ==='
        Write-Host ('Endpoint: {0}:{1} | Database: {2}' -f $configuration.ServerName, $configuration.Port, $configuration.Database)
        Write-Host 'Configuration: same-folder .env'
        $checkResults = Invoke-RdsConnectionReadinessCheck -Configuration $configuration -Thumbprint $ExpectedRootThumbprint -TcpTimeout $TcpTimeoutMilliseconds -SqlTimeout $SqlConnectTimeoutSeconds

        foreach ($result in $checkResults) {
            $status = if ($result.Passed -eq $true) { 'PASS' } elseif ($result.Passed -eq $false) { 'FAIL' } else { 'SKIP/INFO' }
            Write-Host "[$status] $($result.Check): $($result.Detail)"
        }
        Write-Host 'Password is not displayed. No server settings or certificate stores are modified.'
        if (@($checkResults | Where-Object { $_.Passed -eq $false }).Count -gt 0) { exit 1 }
        Write-Host 'All checks passed or returned informational results.'
        exit 0
    }
    catch {
        [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
        exit 1
    }
    finally {
        if ($configuration -and $configuration.SecurePassword) { $configuration.SecurePassword.Dispose() }
    }
}
