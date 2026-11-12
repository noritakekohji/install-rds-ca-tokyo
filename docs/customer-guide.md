# Amazon RDS for SQL Server に Power BI Desktop から接続するときの証明書エラー

**お客様向け確認ガイド | 2026年11月12日 | 資料 v0.3.0**

## まず結論

証明書エラーが「証明書チェーンが信頼されていない」場合、クライアント側の信頼設定が原因である可能性はあります。ただし、エラーの詳細を見ずに「RDSの証明書がPCにない」と断定はできません。ネットワーク、接続先名、認証、暗号化設定など別の原因もあります。

プロジェクト内の改修版PowerShellスクリプトは、AWSの`.p7b`または`.pem`から、設定されたリージョン・CA identifier・Thumbprintに一致するroot CAを1件だけ選び、CurrentUserの信頼されたルートへ登録します。通常は引数なしで実行でき、同じフォルダにバンドルがなければパス入力を求めます。LocalMachineや中間CAは変更しません。

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

改修版は東京のRSA2048 G1をスクリプト内で設定しています。対象RDSが別CAなら管理者が設定値を更新するまで実行しないでください。設定対象と異なる単独PEM（サーバー証明書、中間CA、別CAのrootなど）を指定した場合は条件に合わず登録を中断します。単独PEMでも、設定対象の正しいroot CAそのものであれば利用できます。

## 接続経路に応じた対処

### SQL接続前の端末準備チェック

プロジェクトにはインストーラーとは別に、Test-RdsSqlServerPrerequisites.ps1 があります。引数なしで起動するとRDSエンドポイントを尋ねます。通常のポートは1433です。必要な場合だけ -Port でポートを指定できます。証明書ストアの想定root thumbprint、DNS名前解決、TCP疎通を個別に表示し、設定変更やSQLログインは行いません。

このチェックが通っても、SQL Serverのログインや、SQL ServerのTLS pre-loginで提示されるサーバー証明書の検証まで成功したことにはなりません。Power BI DesktopやSQL接続ドライバーを使った接続確認は別途必要です。失敗した場合は、表示された項目に応じて証明書ストア、DNS、VPN/VPC経路、Security Group/NACL、RDSのポートを確認してください。

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

1. **実際のRDS CAとの一致を確認する** — 元版は東京 RSA2048 G1を固定していました。改修版も標準設定は同じです。異なるCAを使う場合は配布担当者がスクリプト内の設定値を変更します。顧客がCA情報を引数に渡す必要はありません。
2. **Windows向け形式をAWS推奨に合わせる** — 元版はPEMを解析していました。改修版はWindows向け推奨の `.p7b` と元版の `.pem` の両方を読み取ります。bundleに含まれる証明書全ては登録せず、root CAだけを追加します。
3. **配布物の真正性を別途検証する** — 改修版はThumbprintをスクリプト内に設定し、bundle内のrootと照合します。ダウンロード元のTLS確認と顧客向け配布版のハッシュ公開も必要です。
4. **実行を安全にする** — `-WhatIf` とShouldProcess確認をサポートし、CurrentUserストアのみを変更します。エラーは非ゼロ終了コードで返し、重複時は変更せず成功終了します。
5. **サポート対象を明示する** — 現行のRSA2048/RSA4096/ECC384 G1とリージョン名の組み合わせを対象にします。旧CAは対象外とし、AWS側のCA rotationを別途計画してください。
6. **配布版をGitで管理する** — このプロジェクトのGitHubリポジトリはprivateで管理し、お客様へ渡す際は管理された配布先と版・SHA-256を使います。private repoでも顧客がアクセスできるわけではない点に注意してください。
### 評価

元Gist v3は、単一root CA選択とCurrentUser限定ができていました。改修版は `.p7b` / `.pem` 対応、スクリプト内設定との照合、バンドルの自動検索、パス入力、WhatIf、エラー終了コードを加えています。スクリプトのテストは顧客PC/RDSへの接続実証ではありません。

## お客様向け実施手順

1. 接続先がAmazon RDS for SQL Serverであること、RDSエンドポイントとポート（通常1433）、DB識別子、リージョンを確認します。
2. エラー全文を保存し、証明書チェーンの信頼エラーか、ネットワーク/認証エラーかを区別します。
3. AWSコンソールでRDSインスタンスのCA識別子を確認します。
4. AWS公式のRDS証明書ページから `.p7b`（Windows推奨）または `.pem` を取得します。通常はバンドルをスクリプトと同じフォルダに置きます。別フォルダに置いた場合は、引数でパスを指定するか、起動後の入力欄で指定します。
5. 通常は引数なしで実行します。スクリプトは設定済みの東京 RSA2048 G1 rootだけを選び、名前・CA属性・自己発行・Thumbprint・有効期間を確認します。単独ファイルを指定しても、対象rootと一致しなければ何も登録せず終了します。
6. 表示された証明書情報を確認し、PowerShellの確認プロンプトに承認した場合に限り、CurrentUserのRootへ登録します。LocalMachineへの登録はこのスクリプトの対象外です。
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
