#Requires -Version 5.1
<#
.SYNOPSIS
Adds one verified Amazon RDS SQL Server root CA to the current user's Windows trust store.
.DESCRIPTION
Reads an AWS PKCS#7 bundle, selects the root matching the specified region and CA identifier,
checks its thumbprint against a value obtained independently from AWS, then asks before install.
No network access or LocalMachine store changes are performed.
.PARAMETER BundlePath
Path to the AWS PKCS#7 certificate bundle (.p7b).
.PARAMETER Region
AWS region used to construct the expected root CA common name.
.PARAMETER CaIdentifier
AWS RDS CA identifier supported by this release.
.PARAMETER ExpectedThumbprint
Certificate thumbprint independently obtained from an authenticated AWS source.
.OUTPUTS
Writes status to the host. Returns exit code 0 on success/cancellation and non-zero on errors.
.NOTES
Version: 0.2.0
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive installer and the verification details must remain visible to the user.')]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BundlePath = (Join-Path $env:USERPROFILE 'Downloads\global-bundle.p7b'),

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z]{2}(-gov)?-[a-z]+-\d$')]
    [string]$Region,

    [Parameter(Mandatory)]
    [ValidateSet('rds-ca-rsa2048-g1', 'rds-ca-rsa4096-g1', 'rds-ca-ecc384-g1')]
    [string]$CaIdentifier,

    [Parameter(Mandatory)]
    [ValidatePattern('^(?i)[0-9a-f]{40}$')]
    [string]$ExpectedThumbprint
)

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
    }

    return "Amazon RDS $AwsRegion Root CA $generation"
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
        throw "Expected one self-issued root CA named '$ExpectedCommonName' in the bundle; found $($rootCandidates.Count). Confirm the region, CA identifier, and official bundle. Nothing was installed."
    }

    $selectedCertificate = $rootCandidates[0]
    if ($selectedCertificate.Thumbprint -ne $VerifiedThumbprint.Replace(' ', '').ToUpperInvariant()) {
        throw "The selected certificate thumbprint '$($selectedCertificate.Thumbprint)' does not match the independently verified AWS thumbprint. Nothing was installed."
    }

    $now = [DateTime]::UtcNow
    if ($now -lt $selectedCertificate.NotBefore.ToUniversalTime() -or
        $now -gt $selectedCertificate.NotAfter.ToUniversalTime()) {
        throw "The selected root CA is outside its validity period ($($selectedCertificate.NotBefore.ToUniversalTime()) through $($selectedCertificate.NotAfter.ToUniversalTime()) UTC). Check the PC clock and AWS CA details. Nothing was installed."
    }

    return $selectedCertificate
}

try {
    Write-Host '=== Amazon RDS SQL Server root CA installer v0.2.0 ==='
    Write-Host "Bundle: $BundlePath"
    Write-Host "Region: $Region | CA identifier: $CaIdentifier"

    if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
        throw "Certificate bundle not found: '$BundlePath'. Download the official AWS PKCS#7 bundle and retry."
    }

    $resolvedBundlePath = (Resolve-Path -LiteralPath $BundlePath).Path
    $bundleCertificates = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    try {
        $bundleCertificates.Import($resolvedBundlePath)
    }
    catch {
        throw "Could not read '$resolvedBundlePath' as a PKCS#7 certificate bundle. Use the AWS .p7b file. Details: $($_.Exception.Message)"
    }

    if ($bundleCertificates.Count -eq 0) {
        throw 'The PKCS#7 bundle contains no certificates. Nothing was installed.'
    }

    $expectedCommonName = Get-ExpectedRootCommonName -AwsRegion $Region -AwsCaIdentifier $CaIdentifier
    $certificate = Get-RdsRootCertificate `
        -Certificates $bundleCertificates `
        -ExpectedCommonName $expectedCommonName `
        -VerifiedThumbprint $ExpectedThumbprint

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
