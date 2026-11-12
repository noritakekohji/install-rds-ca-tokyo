# Project instructions

- PowerShell 5.1-compatible Windows utility for installing a verified Amazon RDS for SQL Server root CA for the current user.
- Preserve the CurrentUser-only scope. Never import every certificate from an AWS bundle or add an option to bypass server certificate validation.
- Require the caller to identify the RDS region and CA identifier and provide a thumbprint obtained independently from AWS.
- Keep AWS and Microsoft guidance distinct from observed facts and assumptions. Cite official sources and record access dates.
- Never include customer hostnames, credentials, AWS account identifiers, downloaded certificate bundles, or private infrastructure data.
- Run Pester and PSScriptAnalyzer before release. Tests must not install certificates into the trust store.
- Keep customer documentation in `docs/` and reviewed PDF deliverables in `output/pdf/`.
