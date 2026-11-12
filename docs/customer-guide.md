# Amazon RDS for SQL Server に Power BI Desktop から接続するときの証明書エラー

**お客様向け確認ガイド | 2026年11月12日 | 資料 v0.1.0**

## まず結論

証明書エラーが「証明書チェーンが信頼されていない」場合、クライアント側の信頼設定が原因である可能性はあります。ただし、エラーの詳細を見ずに「RDSの証明書がPCにない」と断定はできません。ネットワーク、接続先名、認証、暗号化設定など別の原因もあります。

プロジェクト内の改修版PowerShellスクリプトは、AWSのPKCS#7バンドルから指定リージョン・CA identifierのroot CAを1件だけ選び、別途AWSで確認したThumbprintと一致する場合に限ってCurrentUserの信頼されたルートへ登録します。LocalMachineや中間CAは変更しません。対象RDSが指定CAを使い、Power BIが実行ユーザーのWindows証明書ストアを参照する場合に、CAチェーンの信頼エラーを解消できる可能性があります。

ただし、スクリプトを実行する前にRDSの実際のCA識別子を確認してください。AWSのSQL Server向けWindows接続説明は、Global Bundle PEMよりPKCS#7（`.p7b`）を推奨しています。加えて、Power BI Desktopの2025年2月以降の版では、自己署名証明書のケースに `PBI_SQL_TRUSTED_SERVERS` を使う方法もMicrosoftが案内しています。

## 最初に確認すること

### 1. エラー全文

エラーが次の内容に近い場合、証明書チェーンの信頼が原因候補です。

> The certificate chain was issued by an authority that is not trusted.

この場合でも、提示された証明書を入れれば必ず直るとは限りません。証明書の発行元CA、接続先のホスト名、Power BIの版、接続ドライバーが関係します。別のエラーなら、まずそのエラー内容に合わせて調査します。

### 2. RDSインスタンスのCA

AWSコンソールで対象DBインスタンスの証明書識別子を確認してください。AWS CLIを利用できる場合は、対象アカウントとリージョンを確認したうえで、例えば次のように参照できます。

```powershell
aws rds describe-db-instances `
  --region ap-northeast-1 `
  --query "DBInstances[].{Identifier:DBInstanceIdentifier,Endpoint:Endpoint.Address,CACertificate:CertificateDetails.CAIdentifier}" `
  --output table
```

改修版では実際のCA identifierとリージョンを指定し、別途取得したThumbprintが一致しなければ中断します。

## 接続経路に応じた対処

<PAGEBREAK>
| 状況 | 確認・対処 |
|---|---|
| Power BI DesktopからAmazon RDS for SQL Serverへ直接接続し、エラーがCA信頼エラー | RDSのCAを確認。Windowsクライアントに適切なAWS RDSルートCAを登録し、Power BIを再起動して確認。AWSのSQL Server向け手順はWindowsクライアントでPKCS#7（`.p7b`）を推奨しています。 |
| Power BI Desktopで自己署名証明書の信頼エラー | Microsoft案内の `PBI_SQL_TRUSTED_SERVERS` に対象SQL Server名を登録する方法も選択肢です。信頼対象を必要なサーバー名に限定し、ワイルドカードを広くしないでください。 |
| Power BI Serviceから更新 | Power BI Service自体ではなく、接続に使うオンプレミスデータゲートウェイの構成・証明書ストアを確認します。Desktop側の設定だけでは解決しません。 |
| タイムアウト、名前解決、接続拒否 | 証明書より先に、RDSのPublic access/VPC、Security GroupのTCP 1433、VPN/ネットワーク経路、DNSと接続先を確認します。 |

`TrustServerCertificate=True` は証明書の検証を省略する設定です。通信の暗号化が残る場合でも、接続先の正当性を証明できなくなり、中間者攻撃への保護を弱めます。恒久対処として安易に案内せず、使う場合は組織のセキュリティ担当と影響を確認してください。

## 元Gist v3のレビューと改修版

確認対象: [ca4 — Gist](https://gist.github.com/noritakekohji/66babe40b7ee2f6c506b5057c50ad46a)、2026-11-12閲覧。

### 良い点

- PowerShell 5.1を要求し、エラー時に停止する。
- PEMブロックを証明書としてデコードし、対象CN、CA属性、自己発行ルート、現在の有効期間を検査する。
- 対象証明書がちょうど1つでなければインストールせず終了する。
- インストール先を `CurrentUser\Root` に絞り、実行前に利用者へ確認する。管理者権限が不要で、端末の全ユーザーに影響しない。
- インストール後にThumbprintで登録を確認する。

### 元Gist v3で見つかった改善点

1. **実際のRDS CAとの一致を確認する** — 元版は東京 RSA2048 G1を固定していました。改修版ではリージョンと対応するCA identifierを引数にし、対象CA以外は選択しません。
2. **Windows向け形式をAWS推奨に合わせる** — 元版はPEMを解析していました。改修版はWindows向けに `.p7b` を入力とします。bundleに含まれる証明書全ては登録せず、root CAだけを追加します。
3. **配布物の真正性を別途検証する** — 改修版ではAWSの `describe-certificates` 等から独立に取得したThumbprintを必須入力にして、bundle内のrootと照合します。ダウンロード元のTLS確認と顧客向け配布版のハッシュ公開も必要です。
4. **実行を安全にする** — `-WhatIf` とShouldProcess確認をサポートし、CurrentUserストアのみを変更します。エラーは非ゼロ終了コードで返し、重複時は変更せず成功終了します。
5. **サポート対象を明示する** — 現行のRSA2048/RSA4096/ECC384 G1とリージョン名の組み合わせを対象にします。旧CAは対象外とし、AWS側のCA rotationを別途計画してください。
6. **配布版をGitで管理する** — このプロジェクトのGitHubリポジトリはprivateで管理し、お客様へ渡す際は管理された配布先と版・SHA-256を使います。private repoでも顧客がアクセスできるわけではない点に注意してください。
### 評価

元Gist v3は、単一root CA選択とCurrentUser限定ができていました。改修版は `.p7b` 対応、対象RDS CA identifier・リージョン・Thumbprintの照合、WhatIf、エラー終了コードを加えています。スクリプトのテストは顧客PC/RDSへの接続実証ではありません。

## お客様向け実施手順

1. 接続先がAmazon RDS for SQL Serverであること、RDSエンドポイントとポート（通常1433）、DB識別子、リージョンを確認します。
2. エラー全文を保存し、証明書チェーンの信頼エラーか、ネットワーク/認証エラーかを区別します。
3. AWSコンソールでRDSインスタンスのCA識別子を確認します。
4. AWS公式のRDS証明書ページから、リージョンに適合する `.p7b` を取得します。AWS CLIの `aws rds describe-certificates` など、認証済みAWS情報からCA certificate identifierに対応するThumbprintを別途取得します。
5. READMEの例に従い、まず `-WhatIf` を付けて実行します。Subject、Thumbprint、有効期限と、AWSから独立取得したThumbprintが一致することを確認します。
6. 同じコマンドを `-WhatIf` なしで実行し、PowerShellの確認プロンプトに承認した場合に限り、CurrentUserのRootへ登録します。LocalMachineへの登録はこのスクリプトの対象外です。
7. Power BI Desktopを完全に終了して起動し直し、同じRDSエンドポイント名で再接続します。
8. まだ接続できない場合は、エラー全文、Power BI Desktopのバージョン、RDSのCA識別子、ゲートウェイ利用有無を添えて管理者へ連絡します。認証情報は共有しないでください。

## 参照資料

- AWS, [Using SSL with a Microsoft SQL Server DB instance](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/SQLServer.Concepts.General.SSL.Using.html)（2026-11-12確認）
- AWS, [Using SSL/TLS to encrypt a connection to a DB instance or cluster](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)（2026-11-12確認）
- AWS, [Updating applications to connect to Microsoft SQL Server DB instances using new SSL/TLS certificates](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/ssl-certificate-rotation-sqlserver.html)（2026-11-12確認）
- Microsoft, [Power Query SQL Server connector](https://learn.microsoft.com/en-us/power-query/connectors/sql-server)（2026-11-12確認、2026-10-08更新）
- Microsoft, [SQL Server and client encryption summary](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/sql-server-and-client-encryption-summary?view=sql-server-ver16)（2026-11-12確認）

---

**この資料の範囲:** 公開ドキュメントと提示されたGistのレビューです。個別AWSアカウント、RDS CA設定、ネットワーク経路、Power BI Desktop実機、ゲートウェイ環境は確認していません。接続成功を保証するものではありません。
