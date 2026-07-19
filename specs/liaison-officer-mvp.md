# 連絡将校MVP仕様

## 仕様ID

`RUNTIME-MVP-001`

## 対応Issue

[#13](https://github.com/hayashin1225-lab/ikimono-lab/issues/13)

## 目的

Windows PowerShell上で、承認済みIssueを一件ずつ安全にCodexへ渡し、検査後に連絡将校自身がGit・GitHub操作を行うための初期実装を提供する。

## ファイル構成

`tools/liaison-officer/relay.ps1`を本体とし、設定例、実行ガイド、promptテンプレート、タスク登録・解除スクリプトを置く。外部PowerShellモジュールは使わない。

## モード

| モード | 動作 |
| --- | --- |
| `SelfTest` | 外部状態を変更せず環境・設定・GitHubラベル・ロック可能性を確認する。 |
| `DryRun` | 実行候補一件と予定工程だけを表示し、外部状態を変更しない。 |
| `Once` | 実行可能Issueを一件だけ処理して終了する。 |
| `Scheduled` | タスクスケジューラから一件だけ処理する。 |

## 検収条件

- Windows PowerShell 5.1で構文解析できる。
- `config.local.json`、`.runtime/`、`logs/`、`state/`、`temp/`、`*.log`はGit管理対象外である。
- SelfTestとDryRunはIssue、ラベル、branch、PR、タスクスケジューラ、リポジトリ内容を変更しない。
- OnceとScheduledはlocal FileStream lockと`codex-running`ラベルを併用する。
- Codexのstdout・stderr・終了コード・timeout・プロセスツリー・最終報告JSONを検査する。
- 禁止パス、branch・HEAD変化、Codexのcommit、差分不整合を自動修復せず失敗扱いにする。
- 自動マージ・自動公開・自動再試行を行わない。

## 変更禁止範囲

アプリ本体、`index.html`、README、画像、data URI、保存形式、GitHub Actions、Figma、GitHub Pages、GUI・ゲーム原則は対象外である。

## 初回試行

MVPのマージ後、別の文書一件だけを変更する低リスクIssueで、SelfTest、DryRun、Codexスモークテスト、Once、PR監査、同じPRでの軽微な再作業を順に確認する。Scheduled登録は安定確認後に人間が判断する。
