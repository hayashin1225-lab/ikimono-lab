# AI協働基盤 正本図版

このディレクトリは、`docs/AI_COLLABORATION_PLATFORM.md`から参照される正本図版を格納する。

## 登録図版

| ファイル | 実行形態 | 位置づけ |
|---|---|---|
| `ai-collaboration-direct.svg` | `AI協働基盤.direct` | 直接協働型・標準経路 |
| `ai-collaboration-orchestrated-v1.svg` | `AI協働基盤.orchestrated-v1` | 実行統制型・旧連絡将校MVP |
| `ai-collaboration-hybrid.svg` | `AI協働基盤.hybrid` | 複線協働型・当面の目標 |
| `ai-collaboration-federated.svg` | `AI協働基盤.federated` | 分担協働型・将来形 |

## 管理原則

- 図版の追加、差替え、削除にはPull Requestと人間承認を必要とする。
- 図版だけで新しい仕様を追加せず、本文にも反映する。
- 本文と図版が競合する場合は、本文を規範的定義として優先し、図版を修正する。
- 各図は一つの実行形態に集中し、4モードを一枚へ過剰に統合しない。
- 人間とAI、AI同士、GitHub、品質ゲートの往復・反復を、単純な直列工程へ変形しない。
