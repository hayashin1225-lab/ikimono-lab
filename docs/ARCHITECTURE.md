# アーキテクチャ

## 現在のアプリ構成

- `index.html` 単一ファイルにHTML、CSS、JavaScriptを内包する。
- 画像はdata URI、サーバー・外部ライブラリはなし、GitHub Pagesで公開する。
- 進行は `localStorage` に保存し、iPhone Safariを主要対象とする。

## 段階1半自動開発体制

- **人間**：感覚・違和感・最終判断。
- **ChatGPT**：原発話保存、UX要求、仕様化、工程管理。
- **Figma**：比較案、承認済み画面、視覚上の正本。
- **Codex**：現行調査、最小差分実装、検査。
- **GitHub**：Issue、仕様、PR、判断履歴。
- **公開環境**：実ブラウザ・実端末・実利用評価。

## 成果物の流れ

原発話 → Issue → UX要求 → GUI仕様 → Figma承認画面 → Codex実装 → Pull Request → 公開環境 → 実利用評価 → 原則・判断履歴への反映。必要に応じて差し戻し・反復する。

## 正本分担

| 対象 | 正本 |
| --- | --- |
| 製品目的 | [PRODUCT.md](PRODUCT.md) |
| ゲーム原則 | [GAME_PRINCIPLES.md](GAME_PRINCIPLES.md) |
| GUI共通原則 | [GUI_PRINCIPLES.md](GUI_PRINCIPLES.md) |
| 原要求・原発話 | GitHub Issue |
| UX要求 | GUI仕様書 |
| 視覚配置・寸法・階層 | Figmaの承認済み画面 |
| 状態遷移 | GitHub上の仕様書 |
| 実際の動作 | コード |
| 実装差分・検査結果 | Pull Request |
| 実利用評価 | GUIレビュー記録 |
| 最終判断 | 人間 |

## Figmaの位置づけ

Figmaはコード、製品目的、状態遷移の完全な正本ではない。視覚配置・寸法・情報階層の承認面であり、実装と比較する共有作業面である。

## 差異の分類

Figmaとコードの差異は、自動的にどちらかを正しいとしない。Codexの不要な逸脱、技術的に必要な差異、Figma側の不足、実利用による改善を区別し、判断理由を記録する。
