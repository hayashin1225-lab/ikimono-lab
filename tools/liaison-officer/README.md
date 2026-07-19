# 連絡将校MVP

連絡将校は、[AIオーケストレーション.runtime](../../docs/AI_ORCHESTRATION_RUNTIME.md)の初期実装である。承認済みIssueを一件ずつ選び、Codexの実装とGit・GitHub操作を分離して統制する。意味判断、承認、マージ、公開は自動化しない。

## 前提ソフトウェア

- Windows PowerShell 5.1以上
- Git
- [GitHub CLI](https://cli.github.com/)
- Codex CLI
- Windowsタスクスケジューラ

このMVPはPowerShell標準機能だけを使用する。GitHubトークンやOpenAI APIキーを設定ファイルへ保存しない。

## 初期設定

1. `config.example.json`を`config.local.json`へコピーする。
2. `repoPath`を対象リポジトリの絶対パスへ設定する。
3. 必要に応じてCLIの絶対パス、timeout、ローカルログ保存先を設定する。
4. `gh auth status --hostname github.com`で既存認証を確認する。
5. SelfTestを実行する。

`config.local.json`はGit管理されない。既定のログ、状態、テンポラリは `tools/liaison-officer/.runtime/` 以下に保存され、同じディレクトリのignore規則でGit管理対象外となる。

## 必須ラベル

連絡将校はラベルを自動作成しない。人間が初回だけ必要に応じて作成する。

```powershell
gh label create gm-approved --repo hayashin1225-lab/ikimono-lab --color 0E8A16
gh label create ready-for-codex --repo hayashin1225-lab/ikimono-lab --color 1D76DB
gh label create codex-running --repo hayashin1225-lab/ikimono-lab --color FBCA04
gh label create awaiting-gm-review --repo hayashin1225-lab/ikimono-lab --color 5319E7
gh label create codex-failed --repo hayashin1225-lab/ikimono-lab --color B60205
```

## 実行

```powershell
# 外部状態を変更しない環境確認
.\relay.ps1 -Mode SelfTest

# Codex CLIの安全な一時ディレクトリ smoke test を追加
.\relay.ps1 -Mode SelfTest -RunCodexSmokeTest

# 実行候補を表示するだけ
.\relay.ps1 -Mode DryRun

# 承認済みIssueを一件処理する
.\relay.ps1 -Mode Once

# タスクスケジューラ用。一回に一件だけ処理する
.\relay.ps1 -Mode Scheduled
```

`relay.ps1`は`codex exec`を使用する。対象PCで確認した`codex exec --help`に従い、固定指示とIssueスナップショットを標準入力で渡す。危険なサンドボックス無効化や無制限権限オプションは使用しない。PowerShell 5.1では`ProcessStartInfo.ArgumentList`を使えないため、引数は一か所の安全な引用関数で組み立て、Issue本文をコマンドとして扱わない。

## 成功・失敗・復旧

成功時は`awaiting-gm-review`を付け、PR URLと実行IDをIssueへ記録する。失敗時は`codex-failed`を付け、失敗段階と要約だけをIssueへ記録する。stdout・stderr全文はローカルログだけに保存する。

古いlockやstateが残っていても、自動削除や自動再実行はしない。ログ、PID、実行ID、GitHubラベルを人間とChatGPTが確認して復旧を承認する。連絡将校はreset、clean、stash、作業ブランチ削除を実行しない。

## Scheduled Task

`install-scheduled-task.ps1`は明示的に実行された場合だけ、現在のユーザーがログオン中に5分間隔で`relay.ps1 -Mode Scheduled`を動かすタスクを登録する。PCを強制起動せず、多重実行を禁止する。登録前に`config.local.json`、SelfTest、スクリプト、現在ユーザーでの実行可否を確認する。

```powershell
.\install-scheduled-task.ps1
.\uninstall-scheduled-task.ps1
```

MVP実装時にはタスクを登録しない。自動マージ・自動公開もしない。

## MVPの制約

単一PC、単一リポジトリ、一件処理だけを対象にする。複数Issue並列、分散ロック、GitHub Actions、Figma API、Claude・Gemini等の連携、他AIアダプター、ブラウザ自動テスト、Windowsサービスは対象外である。
