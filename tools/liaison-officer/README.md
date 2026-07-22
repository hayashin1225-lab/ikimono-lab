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

SelfTestは `gh auth status` に加え `gh api user` で実際のloginを読み、設定したリポジトリownerと一致することを確認する。トークンその他の認証情報は表示・保存しない。

## 再作業の明示承認

既存PRを同じブランチで再利用するには、Issueコメントへ `LIAISON_REWORK_APPROVED` と対象PR番号または現在のhead SHAを記載し、`gm-approved` と `ready-for-codex` を再付与する。単なるラベル操作や本文更新では再作業しない。完了後は既存PRへ実行記録を追記し、新規PRは作成しない。

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

Windows PowerShell 5.1では、ネイティブCLIの標準出力・標準エラーをUTF-8として明示的に読み取り、日本語のGitHub JSONとCodex出力を保持するため、`relay-windows.ps1`を入口として使用する。`relay.ps1`は内部の実行本体であり、直接起動しない。

```powershell
# 外部状態を変更しない環境確認
.\relay-windows.ps1 -Mode SelfTest

# Codex CLIの安全な一時ディレクトリ smoke test を追加
.\relay-windows.ps1 -Mode SelfTest -RunCodexSmokeTest

# 実行候補を表示するだけ
.\relay-windows.ps1 -Mode DryRun

# 承認済みIssueを一件処理する
.\relay-windows.ps1 -Mode Once

# タスクスケジューラ用。一回に一件だけ処理する
.\relay-windows.ps1 -Mode Scheduled
```

実行本体は`codex exec`を使用する。対象PCで確認した`codex exec --help`に従い、固定指示とIssueスナップショットを標準入力で渡す。危険なサンドボックス無効化や無制限権限オプションは使用しない。PowerShell 5.1では`ProcessStartInfo.ArgumentList`を使えないため、引数は一か所の安全な引用関数で組み立て、Issue本文をコマンドとして扱わない。

## 成功・失敗・復旧

成功時は`awaiting-gm-review`を付け、PR URLと実行IDをIssueへ記録する。失敗時は、main復帰の成否とは独立して`codex-failed`の付与、`codex-running`等の解除、Issueコメントを順番に試みる。コメントにはrun ID、失敗段階、branch、HEAD、status、実変更・報告パス、diff-check、lock、cleanup到達点の要約を記録する。詳細は実行ディレクトリの`failure-diagnosis.json`と`failure-diagnosis.txt`へUTF-8で保存するため、人間が診断ログをChatGPTへ貼り直すことを通常運用にしない。

ネイティブCLIのstdoutとstderrは別配列として扱う。変更パスはstdoutだけから取得し、LF→CRLF等のstderr警告は`native.stderr.log`へUTF-8で残す。警告文字列をファイル名として検証・stage対象へ混入させない。

古いlockやstateが残っていても、自動削除や自動再実行はしない。dirty差分のためmainへ戻れない場合も、差分を作業ブランチに残したまま診断とGitHub上の失敗状態を記録する。連絡将校はreset、clean、stash、作業ブランチ削除を実行しない。

## Scheduled Task

`install-scheduled-task.ps1`は明示的に実行された場合だけ、現在のユーザーがログオン中に5分間隔で`relay-windows.ps1 -Mode Scheduled`を動かすタスクを登録する。PCを強制起動せず、多重実行を禁止する。登録前に`config.local.json`、SelfTest、スクリプト、現在ユーザーでの実行可否を確認する。

```powershell
.\install-scheduled-task.ps1
.\uninstall-scheduled-task.ps1
```

MVP実装時にはタスクを登録しない。自動マージ・自動公開もしない。

## MVPの制約

単一PC、単一リポジトリ、一件処理だけを対象にする。複数Issue並列、分散ロック、GitHub Actions、Figma API、Claude・Gemini等の連携、他AIアダプター、ブラウザ自動テスト、Windowsサービスは対象外である。
