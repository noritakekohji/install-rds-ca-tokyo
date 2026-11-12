# Changelog

## [0.6.0] - 2026-11-12

### Added
- Double-click customer launcher that runs the connection check, asks before installing a missing configured root CA, then reruns the check
- Per-run text logs with concise console status, password redaction, and automatic cleanup of the temporary `.env`

## [0.5.0] - 2026-11-12

### Added
- Separate connection diagnostic for root CA presence, DNS/TCP reachability, TLS certificate validation, SQL login, database access, and encrypted connection status
- Same-folder .env input for endpoint and SQL credentials without command-line arguments or persistent configuration copies

## [0.3.1] - 2026-11-12

### Fixed
- Define Windows PowerShell 5.1 and PowerShell 7 CI jobs explicitly so GitHub Actions can schedule both shells.

## [0.3.0] - 2026-11-12

### Changed
- Normal use requires no arguments; the script searches beside itself for the default AWS bundle
- An explicit bundle path takes precedence; if defaults are absent, the script prompts for a path
- Region, CA identifier, and expected root thumbprint moved into a configuration block in the script
- Accept both `.p7b` and `.pem`, while rejecting unrelated single certificates
- Tests cover path priority, both bundle formats, and safe rejection of unrelated certificates
- GitHub Actions checks Windows PowerShell 5.1 and PowerShell 7

## [0.2.0] - 2026-11-12

### Added
- AWS PKCS#7 bundle対応のPowerShell CA installer source
- Region/CA identifier/独立確認済みThumbprintによるroot CA選択と検証
- CurrentUser限定、WhatIf、事前確認、導入後検証
- 生成証明書を使ったPester smoke tests
- Windows上でPesterとPSScriptAnalyzerを実行するGitHub Actions CI

### Changed
- READMEを実装済みスクリプトと検証手順に合わせて更新
- お客様向けガイドに改修後の実行方法と安全条件を追記

## [0.1.0] - 2026-11-12

### Added
- RDS for SQL ServerとPower BI DesktopのTLS/証明書エラー切り分け資料
- GistのPowerShell証明書インストーラーに対するレビュー
- お客様向けPDF
