# Amazon RDS SQL Server CA installer

Windows PowerShell tool for adding the configured Amazon RDS root CA to the current user's Windows trust store. Normal use requires no arguments: put `global-bundle.p7b` or `global-bundle.pem` beside the script and run it. The script searches those defaults in that order. If neither is present, it asks for a file path.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- An AWS RDS CA bundle downloaded from the official AWS truststore (`.p7b` is preferred for Windows; `.pem` is also supported)
- The script's configuration block must match the target RDS region and CA certificate identifier

## Usage

### Usual use

1. Download the AWS RDS bundle from the official AWS truststore.
2. Put `global-bundle.p7b` or `global-bundle.pem` in the same folder as the script.
3. Run the script. It selects `.p7b` if both defaults are present, verifies the configured root CA, then asks before installing.

If the bundle is elsewhere, pass its path as the only normal-use argument:

```powershell
.\Install-RdsSqlServerCa.ps1 "$env:USERPROFILE\Downloads\global-bundle.pem"
```

An explicit path takes precedence over files beside the script. If no default file exists and no path was passed, the script prompts for the location. An explicitly supplied but invalid path is rejected instead of silently falling back. `-WhatIf` remains available for a no-change preview.

The customer-facing defaults are in the configuration block near the top of the script: region `ap-northeast-1`, CA identifier `rds-ca-rsa2048-g1`, and its expected root thumbprint. If the target DB uses another CA, an administrator must update these values from AWS details before distributing the script.

Only the current user's trust store is modified. The script does not change `LocalMachine`, install intermediate certificates, download files, change Power BI settings, or bypass certificate validation. Existing certificates are left untouched.

## Verification

```powershell
Invoke-Pester .\tests
Invoke-ScriptAnalyzer .\Install-RdsSqlServerCa.ps1
```

The automated tests use generated certificates and temporary bundles. They do not modify a Windows trust store or prove connectivity to a customer's RDS instance.

## Documentation

- [Customer troubleshooting guide](docs/customer-guide.md)
- [Installer review PDF](output/pdf/rds-sqlserver-ca-installer-review-ja.pdf)
- [Changelog](CHANGELOG.md)

## Version and license

Current version: 0.3.1. This customer-oriented utility is distributed in a private repository. Review the AWS and Microsoft links in the customer guide before each customer deployment because CA bundles and product behavior can change.
