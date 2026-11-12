# Project instructions

- PowerShell 5.1-compatible Windows utility for installing a verified Amazon RDS for SQL Server root CA for the current user.
- Preserve the CurrentUser-only scope. Never import every certificate from an AWS bundle or add an option to bypass server certificate validation.
- Keep the target region, CA identifier, and expected root thumbprint in the script's configuration block so customer users normally need no arguments.
- Accept an optional bundle path as the only normal-use argument; explicit paths win, otherwise search beside the script, then prompt if missing.
- Support the AWS `.p7b` and `.pem` formats, but install only the configured, verified self-issued root.
- Keep AWS and Microsoft guidance distinct from observed facts and assumptions. Cite official sources and record access dates.
- Never include customer hostnames, credentials, AWS account identifiers, downloaded certificate bundles, or private infrastructure data.
- Run Pester and PSScriptAnalyzer before release. Tests must not install certificates into the trust store.
- Keep customer documentation in `docs/` and reviewed PDF deliverables in `output/pdf/`.
