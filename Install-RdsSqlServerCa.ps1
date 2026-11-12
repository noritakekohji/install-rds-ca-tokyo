#Requires -Version 5.1
<#
.SYNOPSIS
Installs the configured Amazon RDS SQL Server root CA for the current Windows user.
.DESCRIPTION
Looks for the configured AWS bundle beside this script. If none is present, it prompts for a path.
An explicit -BundlePath always takes precedence. PKCS#7 (.p7b) and PEM (.pem) are supported;
only the pinned, self-issued root CA is added to CurrentUser\Root.
.PARAMETER BundlePath
Optional path to a .p7b or .pem file. If omitted, the script folder is searched first.
.NOTES
Version: 0.3.0. Change the configuration block below when the target RDS CA changes.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive installer and the verification details must remain visible to the user.')]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$BundlePath
)

# Customer deployment settings. Keep these aligned with the target RDS DB instance.
$RdsRegion = 'ap-northeast-1'
$RdsCaIdentifier = 'rds-ca-rsa2048-g1'
# AWS RDS describe-certificates thumbprint for this CA; refresh it when changing CA settings.
$ExpectedRootThumbprint = 'D790BBB661BAFA4101829F103D639BEFA300F9A4'

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-ExpectedRootCommonName {
    param(
        [Parameter(Mandatory)][string]$AwsRegion,
        [Parameter(Mandatory)][string]$AwsCaIdentifier
    )

    $generation = switch ($AwsCaIdentifier) {
        'rds-ca-rsa2048-g1' { 'RSA2048 G1' }
        'rds-ca-rsa4096-g1' { 'RSA4096 G1' }
        'rds-ca-ecc384-g1' { 'ECC384 G1' }
        default { throw "Unsupported RDS CA identifier '$AwsCaIdentifier'. Update the script configuration only after checking the AWS CA details." }
    }

    return "Amazon RDS $AwsRegion Root CA $generation"
}

function Resolve-RdsBundlePath {
    param(
        [AllowNull()][string]$RequestedPath,
        [Parameter(Mandatory)][string]$ScriptDirectory
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) {
            throw "The specified bundle file does not exist: '$RequestedPath'. No fallback file was used."
        }
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    foreach ($fileName in @('global-bundle.p7b', 'global-bundle.pem')) {
        $candidate = Join-Path $ScriptDirectory $fileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Write-Host "Using bundle beside the script: $candidate"
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    Write-Host 'No global-bundle.p7b or global-bundle.pem was found beside the script.'
    while ($true) {
        $manualPath = Read-Host 'Enter the full path to the AWS .p7b or .pem bundle (blank to cancel)'
        if ([string]::IsNullOrWhiteSpace($manualPath)) {
            throw 'Bundle selection was cancelled. Nothing was installed.'
        }
        if (Test-Path -LiteralPath $manualPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $manualPath).Path
        }
        Write-Warning "File not found: '$manualPath'. Enter another path or leave blank to cancel."
    }
}

function Import-RdsCaCertificate {
    param([Parameter(Mandatory)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $certificates = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection

    if ($extension -eq '.p7b') {
        try {
            $certificates.Import($Path)
        }
        catch {
            throw "Could not read '$Path' as a PKCS#7 bundle. Details: $($_.Exception.Message)"
        }
    }
    elseif ($extension -eq '.pem') {
        $content = [System.IO.File]::ReadAllText($Path)
        $blocks = [regex]::Matches(
            $content,
            '-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----',
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
        if ($blocks.Count -eq 0) {
            throw "No PEM certificate was found in '$Path'. Use the AWS global bundle PEM or PKCS#7 file."
        }

        foreach ($block in $blocks) {
            try {
                $der = [Convert]::FromBase64String(($block.Groups[1].Value -replace '\s', ''))
                [void]$certificates.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($der))
            }
            catch {
                throw "Invalid certificate data in '$Path'. Details: $($_.Exception.Message)"
            }
        }
    }
    else {
        throw "Unsupported bundle extension '$extension'. Choose an AWS .p7b or .pem file."
    }

    if ($certificates.Count -eq 0) {
        throw "No certificates were found in '$Path'. Nothing was installed."
    }
    return ,$certificates
}

function Get-RdsRootCertificate {
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2Collection]$Certificates,
        [Parameter(Mandatory)][string]$ExpectedCommonName,
        [Parameter(Mandatory)][string]$VerifiedThumbprint
    )

    $rootCandidates = @()
    foreach ($certificate in $Certificates) {
        $basicConstraints = $certificate.Extensions |
            Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] } |
            Select-Object -First 1
        $commonName = $certificate.GetNameInfo(
            [System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )

        if ($basicConstraints -and $basicConstraints.CertificateAuthority -and
            $certificate.Subject -eq $certificate.Issuer -and
            $commonName -eq $ExpectedCommonName) {
            $rootCandidates += $certificate
        }
    }

    if ($rootCandidates.Count -ne 1) {
        throw "Expected one self-issued root CA named '$ExpectedCommonName' in the file; found $($rootCandidates.Count). Confirm the AWS global bundle and script settings. Nothing was installed."
    }

    $selectedCertificate = $rootCandidates[0]
    if ($selectedCertificate.Thumbprint -ne $VerifiedThumbprint.Replace(' ', '').ToUpperInvariant()) {
        throw "The selected certificate thumbprint '$($selectedCertificate.Thumbprint)' does not match the configured AWS thumbprint. Nothing was installed."
    }

    $now = [DateTime]::UtcNow
    if ($now -lt $selectedCertificate.NotBefore.ToUniversalTime() -or
        $now -gt $selectedCertificate.NotAfter.ToUniversalTime()) {
        throw "The selected root CA is outside its validity period. Check the PC clock and script configuration. Nothing was installed."
    }

    return $selectedCertificate
}

# Dot-sourcing exposes helper functions to tests without running the installer.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Write-Host '=== Amazon RDS SQL Server root CA installer v0.3.0 ==='
        Write-Host "Target: $RdsRegion / $RdsCaIdentifier"

        $resolvedBundlePath = Resolve-RdsBundlePath -RequestedPath $BundlePath -ScriptDirectory $PSScriptRoot
        Write-Host "Bundle: $resolvedBundlePath"
        $bundleCertificates = Import-RdsCaCertificate -Path $resolvedBundlePath
        $expectedCommonName = Get-ExpectedRootCommonName -AwsRegion $RdsRegion -AwsCaIdentifier $RdsCaIdentifier
        $certificate = Get-RdsRootCertificate `
            -Certificates $bundleCertificates `
            -ExpectedCommonName $expectedCommonName `
            -VerifiedThumbprint $ExpectedRootThumbprint

        Write-Host "Subject     : $($certificate.Subject)"
        Write-Host "Issuer      : $($certificate.Issuer)"
        Write-Host "Thumbprint  : $($certificate.Thumbprint)"
        Write-Host "Valid until : $($certificate.NotAfter.ToUniversalTime()) UTC"
        Write-Host 'Store       : CurrentUser\Root'

        $storePath = 'Cert:\CurrentUser\Root'
        $existingCertificate = Get-ChildItem -LiteralPath $storePath |
            Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } |
            Select-Object -First 1
        if ($existingCertificate) {
            Write-Host 'ALREADY INSTALLED: This exact certificate is present in CurrentUser\Root.'
            exit 0
        }

        if (-not $PSCmdlet.ShouldProcess("CurrentUser\Root ($($certificate.Thumbprint))", 'Install verified AWS RDS root CA')) {
            Write-Host 'No certificate was installed.'
            exit 0
        }

        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            'Root',
            [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser
        )
        try {
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $store.Add($certificate)
        }
        finally {
            $store.Close()
        }

        $installedCertificate = Get-ChildItem -LiteralPath $storePath |
            Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } |
            Select-Object -First 1
        if (-not $installedCertificate) {
            throw 'Post-install verification failed: the certificate was not found in CurrentUser\Root.'
        }

        Write-Host 'SUCCESS: Verified root CA installed for the current user.'
        Write-Host 'Restart Power BI Desktop and retry using the RDS endpoint hostname.'
        exit 0
    }
    catch {
        [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
        exit 1
    }
}
