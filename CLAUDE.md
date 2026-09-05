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
make compile     # byte-compile（警告をエラー扱い）。古い .elc を先に消す
make test        # ERT（fixture リプレイ。実プロセスは使わない）
make test-live   # 実 CLI を使う ERT（tag live）。手動でのみ実行
make lint        # checkdoc（+ package-lint があれば）
```

`make test-live` は全部で数分・$1 弱かかる。1 本だけ回すときは
`$(BATCH) -l test/ecc-test-helpers.el -l test/ecc-live-test.el --eval '(ert-run-tests-batch-and-exit (quote ecc-test-live-plan))'`
のように selector で絞る。

## CLI を起動するときの必須ルール

開発・テストで `claude` を起動するときは **必ず** 次を付ける:

```
--settings '{"enabledPlugins":{"emacs-bridge@emacs-gravity-marketplace":false}}'
--model haiku --max-budget-usd 0.5
```

- `--settings` の `enabledPlugins`: この環境には emacs-gravity プラグイン（emacs-bridge 4.6.2）の
  hooks が入っている。**ハングはしない**（2026-09-05 に 2 回確認。hook は
  `{"reason":"no_capable_terminal"}` を返して手を引き、`--permission-prompt-tool stdio` に落ちる）が、
  fixture の記録では止めておく: hook events・1〜2 秒の遅延・gravity 自身の MCP と system prompt が混ざらない。
  セッション単位なので、ユーザーの対話用セッションには影響しない。
- **`--safe-mode` は使わない。** MCP サーバー・skills・カスタムコマンド・agents まで丸ごと落ちてしまい、
  この package が表示したいもの（FR-INP-1〜3 の `/` 補完、FR-DASH の agents、FR-MCP）が消える。
  検証結果は `docs/verified.md` の D2。
- `--model haiku` と `--max-budget-usd`: コスト上限。
- stream-json には `--verbose` と `--permission-prompt-tool stdio` と `:connection-type 'pipe` が必須（計画 §2.1, §9）。

Elisp 側では `ecc-safe-mode` は nil が既定。止めたいプラグインは `ecc-disabled-plugins` に入れる。

## コーディング規約

- `lexical-binding: t`。プレフィックス `ecc-`、内部関数は `ecc--`。
- JSON を触るのは `ecc-protocol.el` と `ecc-proc.el` だけ。magit-section を require するのは `ecc-render.el` だけ（計画 §0）。
- `json-serialize` の配列はベクタ。`nil` は `{}`。`null` は `:null`、偽は `:false`（計画 §2.3）。
- セッションバッファで font-lock を使わない。face は挿入時に付ける。
- 例外を握りつぶさない。dispatch の失敗はログと `unknown` ノードに残す。

## テスト

- 各フェーズで計画 §8 に沿った ERT を書く。`make test` が通ることをフェーズ完了の条件に含める。
- fixture は `test/fixtures/*.jsonl`。`scripts/record-fixture.sh` で実 CLI から記録する。
- 履歴（`~/.claude/projects` の jsonl）の fixture は `test/fixtures/history/*.jsonl`。
  `scripts/record-history.sh` で記録する（永続化ありで数ターン喋らせ、書かれた jsonl を取り込む）。
  ストリームの fixture と同じディレクトリに置かないこと（`ecc-dispatch-test-no-fixture-line-is-unknown`
  が全 fixture をストリームとして流すため）。
- 描画のスナップショットは主要ケースに絞る。
- 複数セッションにまたがる機能（Inbox、ダッシュボード）のテストは必ず 2 セッション以上で書く
  （`ecc-model-pending-all` の破壊的 sort は 1 セッションでは出なかった）。
- `format-mode-line` は batch では空文字列を返す。mode-line の `:eval` は関数を直接呼んで検証する。

## 作業の進め方

- 1 フェーズ = 1 セッションを目安にする。フェーズの受け入れ基準を満たしたら報告し、次に進む前にユーザーの確認を取る。
- フェーズ内でも意味のある単位でコミットする。メッセージは Conventional Commits（`feat(proc): ...`, `fix(render): ...`, `test: ...`, `docs: ...`）。
- 要件と衝突する発見があれば `docs/decisions.md` に記録してユーザーに確認する。勝手に要件を変えない。
