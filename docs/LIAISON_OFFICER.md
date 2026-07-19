# 連絡将校MVP

## 責務

連絡将校はAIオーケストレーション.runtimeの初期実装である。GitHub Issueの候補選択、前提検査、ローカルロック、GitHubラベル遷移、Issueスナップショット作成、Codex CLI起動、差分検査、commit・push・PR作成、証跡保存を担う。

人間、ChatGPT、Codexの意味判断を代替しない。Codexが実装する範囲と、連絡将校がGit・GitHubを操作する範囲を分離する。

## 実行条件と選択

対象はOpenで、`gm-approved` と `ready-for-codex` があり、`codex-running`、`awaiting-gm-review`、`codex-failed` がないIssueだけである。複数候補は作成日時が古い順、同時刻はIssue番号が小さい順に一件だけ選ぶ。Issue #13はBootstrap Issueのため実行対象にしない。

初回実行で規定ブランチ、リモートブランチ、Open PRが存在すれば停止する。再作業は既存Open PR、規定head、Issue参照、前回の実行ID、新しい修正要求、承認ラベルがそろう場合だけ同じブランチとPRを再利用する。

## 排他と状態

ローカルではFileStreamを`FileShare.None`で保持する。GitHubでは`codex-running`を追加・再取得して確認してから`ready-for-codex`を外す。ロックや状態が古く見えても自動削除・自動復旧しない。PID、開始時刻、実行IDを報告して安全停止する。

成功時は実行状態ラベルを整理し、`awaiting-gm-review`を付け、`gm-approved`を保持する。失敗時は可能な範囲で実行中ラベルを外し、`codex-failed`を付ける。ラベル自体は自動作成しない。

## Codex実行と検査

連絡将校は固定したIssueスナップショット、固定安全指示、実行IDをCodexへ渡す。Codexはbranch、commit、push、PR、Issue・ラベル、merge、公開を行わない。標準出力と標準エラーは別ログへ保存し、timeout時はプロセスツリーを終了する。

終了コードだけで成功扱いにしない。開始ブランチ・HEADの維持、未追跡を含む差分、`git diff --check`、禁止パス、最終報告JSON、報告ファイルと実差分の照合を確認する。

## 失敗と復旧

失敗は`preflight`、`selection`、`lock`、`github-state`、`branch`、`issue-snapshot`、`codex-start`、`codex-timeout`、`codex-exit`、`report-parse`、`validation`、`commit`、`push`、`pull-request`で記録する。自動再試行、reset、clean、stash、変更破棄は行わない。人間とChatGPTがログとGitHub状態を確認してから復旧を承認する。

## セキュリティと運用

トークン、Cookie、APIキー、パスワードを設定・ログ・GitHubコメントへ保存しない。GitHub投稿には要約だけを使い、絶対パスとWindowsユーザー名を含めない。`config.local.json`はローカル専用である。

Scheduled Taskは人間が明示的に登録した場合だけ5分間隔・ログオン中のみで動かす。MVP実装時にタスク登録や実Issue処理は行わない。
