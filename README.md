# Amazon RDS SQL Server CA installer

Windows PowerShell tool for adding the configured Amazon RDS root CA to the current user's Windows trust store. Normal use requires no arguments: put `global-bundle.p7b` or `global-bundle.pem` beside the script and run it. The script searches those defaults in that order. If neither is present, it asks for a file path.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- An AWS RDS CA bundle downloaded from the official AWS truststore (`.p7b` is preferred for Windows; `.pem` is also supported)
- The script's configuration block must match the target RDS region and CA certificate identifier

## Usage

### Customer one-click flow

Prepare the temporary `.env` connection file and place `global-bundle.p7b` or `global-bundle.pem` beside the scripts. Then double-click `Run-RdsSqlServerCheck.bat`.

The launcher first runs the connection readiness check. It runs the certificate installer only when the expected root CA is missing, asks the user before adding that CA to `CurrentUser\Root`, and reruns the connection check after installation. It does not install a certificate for DNS, TCP, TLS, SQL login, or database errors unrelated to a missing expected root CA. No administrator elevation is required.

Detailed output is written to a uniquely named `RdsSqlServerCheck-*.log` text file beside the launcher. The console shows only short progress and OK/NG messages. Password values are redacted from captured output. The `.env` file is retained after a run and is never deleted or modified by the launcher. Remove it manually when you no longer need it, and do not share it. The log can contain the endpoint, database name, resolved IP addresses, and error details; review it before sharing it outside the customer environment. If `.env` is missing or the launcher cannot create a log, the tool stops without installing a certificate.

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
Invoke-ScriptAnalyzer .\Test-RdsSqlServerPrerequisites.ps1
```

The automated tests use generated certificates, temporary bundles, and mocked network calls. They do not modify a Windows trust store or prove connectivity to a customer's RDS instance.

## Connection readiness check

Run Test-RdsSqlServerPrerequisites.ps1 separately from the certificate installer; it takes no arguments. Put a temporary .env file beside the script using .env.example as a template. It contains only the RDS endpoint DNS name, port, database, SQL login, and password. Use the RDS endpoint DNS name rather than its resolved IP so TLS can validate the certificate hostname.

The password is plaintext in .env as requested. The checker reads the file but does not create, modify, copy, or retain it elsewhere; it never prints the password. Keep .env out of Git and remove the temporary file from the client after the diagnostic run.

The checker reports the configured RDS root CA presence/validity, DNS, and TCP checks, then makes a real SQL connection using the configured database and login. The SQL client uses Encrypt=True and TrustServerCertificate=False, so a successful TLS check means the presented certificate chain and endpoint name passed normal client validation. It also reports SQL login/database access and queries encrypt_option when SQL permissions allow. It never installs certificates or changes RDS/network settings.

## Documentation

- [Customer troubleshooting guide](docs/customer-guide.md)
- [Prerequisite checker](Test-RdsSqlServerPrerequisites.ps1)
- [.env format example](.env.example)
- [Installer review PDF](output/pdf/rds-sqlserver-ca-installer-review-ja.pdf)
- [Changelog](CHANGELOG.md)

## Version and license

Current version: 0.6.1. This customer-oriented utility is distributed in a private repository. Review the AWS and Microsoft links in the customer guide before each customer deployment because CA bundles and product behavior can change.
