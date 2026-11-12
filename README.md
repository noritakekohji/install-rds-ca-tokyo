# Amazon RDS SQL Server CA installer

Windows PowerShell tool for adding the Amazon RDS root CA used by a SQL Server DB instance to the current user's Windows trust store. The script accepts AWS's PKCS#7 bundle and deliberately installs only the single root CA selected by region, CA identifier, and a separately verified certificate thumbprint.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- An AWS RDS CA bundle downloaded from the official AWS truststore (`.p7b` recommended for Windows)
- The DB instance region and CA certificate identifier, checked in AWS before running
- The expected thumbprint obtained independently from AWS, for example through `aws rds describe-certificates`

## Usage

First verify the DB instance CA identifier and obtain its thumbprint from AWS:

```powershell
aws rds describe-certificates `
  --region ap-northeast-1 `
  --query "Certificates[?CertificateIdentifier=='rds-ca-rsa2048-g1'].Thumbprint | [0]" `
  --output text
```

Download the appropriate official PKCS#7 bundle, then run a non-mutating preview:

```powershell
.\Install-RdsSqlServerCa.ps1 `
  -BundlePath "$env:USERPROFILE\Downloads\global-bundle.p7b" `
  -Region ap-northeast-1 `
  -CaIdentifier rds-ca-rsa2048-g1 `
  -ExpectedThumbprint '<thumbprint-verified-separately>' `
  -WhatIf
```

After verifying the displayed certificate Subject, Issuer, Thumbprint, and expiry against the official AWS record, repeat without `-WhatIf`. PowerShell prompts before writing to `Cert:\CurrentUser\Root`. Restart Power BI Desktop after installation.

Only the current user's trust store is modified. The script does not change `LocalMachine`, install intermediate certificates, download files, change Power BI settings, or bypass certificate validation. Existing certificates are left untouched.

## Verification

```powershell
Invoke-Pester .\tests
Invoke-ScriptAnalyzer .\Install-RdsSqlServerCa.ps1
```

The automated tests use generated test certificates and temporary PKCS#7 files. They do not modify a Windows trust store or prove connectivity to a customer's RDS instance.

## Documentation

- [Customer troubleshooting guide](docs/customer-guide.md)
- [Installer review PDF](output/pdf/rds-sqlserver-ca-installer-review-ja.pdf)
- [Changelog](CHANGELOG.md)

## Version and license

Current version: 0.2.0. This customer-oriented utility is distributed in a private repository. Review the AWS and Microsoft links in the customer guide before each customer deployment because CA bundles and product behavior can change.
