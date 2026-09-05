# emacs-claude-code — 開発者向けメモ（Claude Code 用）

このリポジトリは Emacs から Claude Code CLI を使うパッケージ `ecc` を作るもの。

## 最初に読むもの

1. `REQUIREMENTS.md` — 要件の正本（106 件）。要件 ID（FR-xxx-N, NFR-N）で参照する。
2. `IMPLEMENTATION_PLAN.md` — 実装計画。§0 の指示、§7 のフェーズ順に従う。
3. `docs/verified.md` — 実機で確認済みの CLI 挙動。§10 の未検証事項を確認したらここに追記する。
4. `docs/decisions.md` — 要件と衝突する発見と決定の記録。

## 環境

- Emacs: `emacs` は PATH に無い。`/opt/homebrew/Cellar/emacs-plus@32/32.0.50/Emacs.app/Contents/MacOS/Emacs`（Emacs 32 開発版）。`Makefile` の `EMACS` 変数で指定済み。
- 依存パッケージは `~/.emacs.d/elpa` にある（magit-section, markdown-mode, nerd-icons, spinner, vterm）。`transient` は Emacs 本体に同梱。`package-initialize` で読める。`package-lint` は未導入（lint は自動でスキップする）。
- Claude Code CLI: `claude` 2.1.261。

## コマンド

```
make compile     # byte-compile（警告をエラー扱い）
make test        # ERT（fixture リプレイ。実プロセスは使わない）
make test-live   # 実 CLI を使う ERT（tag live）。手動でのみ実行
make lint        # checkdoc（+ package-lint があれば）
```

## CLI を起動するときの必須ルール

開発・テストで `claude` を起動するときは **必ず** 次を付ける:

```
--safe-mode --model haiku --max-budget-usd 0.5
```

- `--safe-mode`: この環境には emacs-gravity プラグインの hooks が入っており、無いと AskUserQuestion がハングする。
- `--model haiku` と `--max-budget-usd`: コスト上限。
- stream-json には `--verbose` と `--permission-prompt-tool stdio` と `:connection-type 'pipe` が必須（計画 §2.1, §9）。

## コーディング規約

- `lexical-binding: t`。プレフィックス `ecc-`、内部関数は `ecc--`。
- JSON を触るのは `ecc-protocol.el` と `ecc-proc.el` だけ。magit-section を require するのは `ecc-render.el` だけ（計画 §0）。
- `json-serialize` の配列はベクタ。`nil` は `{}`。`null` は `:null`、偽は `:false`（計画 §2.3）。
- セッションバッファで font-lock を使わない。face は挿入時に付ける。
- 例外を握りつぶさない。dispatch の失敗はログと `unknown` ノードに残す。

## テスト

- 各フェーズで計画 §8 に沿った ERT を書く。`make test` が通ることをフェーズ完了の条件に含める。
- fixture は `test/fixtures/*.jsonl`。`scripts/record-fixture.sh` で実 CLI から記録する。
- 描画のスナップショットは主要ケースに絞る。

## 作業の進め方

- 1 フェーズ = 1 セッションを目安にする。フェーズの受け入れ基準を満たしたら報告し、次に進む前にユーザーの確認を取る。
- フェーズ内でも意味のある単位でコミットする。メッセージは Conventional Commits（`feat(proc): ...`, `fix(render): ...`, `test: ...`, `docs: ...`）。
- 要件と衝突する発見があれば `docs/decisions.md` に記録してユーザーに確認する。勝手に要件を変えない。
