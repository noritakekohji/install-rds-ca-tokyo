#Requires -Version 5.1
<#
.SYNOPSIS
Checks Windows-side prerequisites for reaching an Amazon RDS for SQL Server endpoint.
.DESCRIPTION
Checks the expected RDS root CA in the Windows root stores, resolves the endpoint,
and attempts a TCP connection. It does not log in to SQL Server or validate the
server's TLS certificate during a SQL Server pre-login handshake.
.PARAMETER ServerName
RDS endpoint DNS name. If omitted, the script prompts for it.
.PARAMETER Port
TCP port. Defaults to 1433.
.NOTES
No settings are changed and no credentials are requested.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive diagnostic output is the customer-facing result.')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerName,
    [ValidateRange(1, 65535)]
    [int]$Port = 1433
)

# Keep these values aligned with the installer configuration and the target RDS CA.
$ExpectedRootThumbprint = 'D790BBB661BAFA4101829F103D639BEFA300F9A4'
$TcpTimeoutMilliseconds = 5000

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([string]::IsNullOrWhiteSpace($ServerName)) {
            $ServerName = Read-Host 'Enter the RDS SQL Server endpoint DNS name'
        }
        if ([string]::IsNullOrWhiteSpace($ServerName)) {
            throw 'No endpoint was provided. Nothing was changed.'
        }

        Write-Host '=== RDS for SQL Server prerequisite check ==='
        Write-Host ('Endpoint: {0}:{1}' -f $ServerName, $Port)
        $checkResults = Invoke-RdsPrerequisiteCheck `
            -HostName $ServerName `
            -TcpPort $Port `
            -Thumbprint $ExpectedRootThumbprint `
            -TimeoutMilliseconds $TcpTimeoutMilliseconds

        foreach ($result in $checkResults) {
            $status = if ($result.Passed) { 'PASS' } else { 'FAIL' }
            Write-Host "[$status] $($result.Check): $($result.Detail)"
        }
        Write-Host 'This check does not perform SQL authentication or validate the server certificate in a SQL/TLS handshake.'
        if (@($checkResults | Where-Object { -not $_.Passed }).Count -gt 0) { exit 1 }
        Write-Host 'All configured prerequisites passed.'
        exit 0
    }
    catch {
        [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
        exit 1
    }
}
