[English](README.md) | **日本語**

---

# Emacs Client for Claude Code

Claude Code CLI 向けの Emacs クライアントです。通常の Emacs バッファ内で直接対話を行うことができます。

![Emacs 29.1+](https://img.shields.io/badge/Emacs-29.1%2B-7F5AB6)
![Claude Code CLI](https://img.shields.io/badge/Claude%20Code-CLI-D97757)

![セッション：プロンプトを送り、Edit を許可すると、左のソースバッファが変更を取り込む](docs/images/session.gif)

**ドキュメント:** <https://wakamenod.github.io/emacs-claude-code/ja/>

> **1.0 未満です。** ecc はまだ安定版ではなく、破壊的変更が入る可能性が高い段階です。コマンド、キーバインド、設定はリリースをまたいで変更・削除されることがあります。更新する前に [CHANGELOG.md](CHANGELOG.md) を確認してください。

## 概要

ecc は `claude` をヘッドレスモードで実行し、パイプ経由で stream-json プロトコルを用いて通信を行うことで、
標準的な Emacs バッファに対話を描画します。

対話履歴は通常のバッファテキストであるため、検索、`occur`、ナローイング、コピー、Markdown へのエクスポートといった標準的な Emacs の操作をそのまま利用できます。
faceはテキスト挿入時に適用されるため、`M-x customize` によるカスタマイズが可能です。

### スコープとトレードオフ

- **ターミナルエミュレーションなし:** CLI のターミナル UI は再現しません。実際のターミナル操作が必要な場合は、`ecc-tui-open` で実行中のセッションをターミナルへ引き渡し、完了後に戻すことができます。
- **Claude Code 専用:** Claude Code の独自プロトコルと直接通信するため、汎用の LLM フロントエンドではありません。
- **軽量な描画処理:** Markdown、表、diff は完全な外部実装ではなく、ecc 独自の内蔵パーサーによって描画されます。
- **プロトコルの直接反映:** 権限の確認要求、利用状況データ（`get_usage`）、過去の会話ログは、推測を交えず CLI から直接取得されます。

### 主な機能

- **[Diff レビュー](https://wakamenod.github.io/emacs-claude-code/ja/features/review/):** セッション中に行われたすべての変更を 1 つの `diff-mode` バッファで確認できます。ハンク（変更ブロック）にインラインコメントを付けて、まとめて 1 つのプロンプトとして送信可能です。
- **[インタラクティブな編集](https://wakamenod.github.io/emacs-claude-code/ja/features/review/#適用前の提案をレビューする):** 提案されたファイル編集を適用前に確認・修正できます。
- **[プランモード](https://wakamenod.github.io/emacs-claude-code/ja/features/review/#プランモード):** 提案された実行計画を、編集可能なバッファ内で確認・調整しながら進められます。
- **[グローバル操作](https://wakamenod.github.io/emacs-claude-code/ja/reference/key-bindings/):** どのバッファからでも保留中のツール実行リクエストを許可・拒否できます。
- **[セッション管理](https://wakamenod.github.io/emacs-claude-code/ja/features/sessions/):** ダッシュボードから複数の同時並行セッションを整理・管理できます。
- **安全なデフォルト設定:** 権限プロンプトはデフォルトで「拒否」に設定されています。内蔵のループバック MCP サーバーはデフォルトで無効化されており、Elisp の評価ツールも明示的な有効化が必要です。

## 動作要件

- **Emacs 29.1 以上**（`transient` は Emacs に同梱されています。必須の外部パッケージはありません）
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)**（`PATH` 上に配置されているか、`ecc-executable` で指定されていること）

### 任意の依存関係

以下のパッケージがインストールされている場合、機能が強化されます（未導入でも代替処理が行われ、エラーにはなりません）：

- [ghostel](https://github.com/dakra/ghostel) — セッションをターミナルへ引き渡す機能
- [posframe](https://github.com/tumashu/posframe) — `/btw` や利用状況のポップアップ表示
- [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) — ツールアイコンの表示
- [markdown-mode](https://github.com/jrblevin/markdown-mode) — プランバッファおよびレビューバッファのメジャーモード

## インストール

ecc は MELPA に登録されていません。本リポジトリから直接インストールしてください。

### Emacs 30 以上（`use-package` と `:vc`）

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

*※ 特定のコミットに固定したい場合は `:rev "<commit-sha>"` を指定してください。*

### Emacs 29（`package-vc-install`）
```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

その後、通常の `use-package` 宣言（`:vc` なし）で設定します。

<details>
<summary>straight.el、Elpaca、手動クローン</summary>

リポジトリ名が `emacs-claude-code` でパッケージ名が `ecc` であるため、レシピ内でパッケージ名を明示的に指定する必要があります。

```elisp
;; straight.el
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))

;; Elpaca
(use-package ecc
  :ensure (ecc :host github :repo "wakamenod/emacs-claude-code"))
```

手動クローンの場合：

```sh
git clone https://github.com/wakamenod/emacs-claude-code ~/.emacs.d/site-lisp/emacs-claude-code
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/emacs-claude-code")
(require 'ecc)
```

`M-x ecc-start` は自動ロードされます。`ecc-global-map` を `use-package` の外部でバインドする場合は、事前に ecc がロードされていることを確認するか、`use-package` の `:bind-keymap` を使用してください。
</details>

## 設定例

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  ;; `ecc-global-map' により、任意のバッファから保留中のリクエストに応答可能
  ;; `:bind-keymap' により、プレフィックスキー入力時まで ecc の読み込みを遅延
  :bind-keymap ("C-c c" . ecc-global-map)
  :custom
  (ecc-permission-mode "auto")            ; nil なら CLI のデフォルトを維持
  (ecc-notify-level 'pulse)               ; nil, 'message, 'pulse, 'desktop
  (ecc-usage-display 'posframe)           ; posframe が必要（未導入時は 'window）
  (ecc-btw-display 'posframe)
  (ecc-prompt-suggestions-enabled t))
```

その他の設定項目については、`M-x customize-group RET ecc` を実行するか、[設定リファレンス](https://wakamenod.github.io/emacs-claude-code/ja/reference/configuration/) を参照してください。

## クイックスタート

1. プロジェクト内のバッファで `M-x ecc-start` を実行してセッションを開始します。
2. 画面下部のプロンプト領域にメッセージを入力します。
3. `C-c C-c` で送信します（`RET` は改行）。
4. Claude がツール実行の権限を求めてきたら、`C-c C-a` で許可、`C-c C-d` で拒否します。**デフォルトは拒否です。**
5. `C-c ?` でコマンドメニューを開きます。

## キーバインド

### グローバルマップ (`C-c c`)

どのバッファからでも利用可能です：

| キー | コマンド | 操作 |
| --- | --- | --- |
| `c` | `ecc-start` | セッションを開始 |
| `r` | `ecc-resume-menu` | セッションを再開 |
| `R` | `ecc-rename-session` | セッションの名前を変更 |
| `v` | `ecc-show-session` | セッションのプロンプトへ移動 |
| `i` | `ecc-interrupt` | 実行中のターンを中断 |
| `t` | `ecc-tui-open` | セッションを端末へ引き渡す |
| `a` | `ecc-answer-allow` | 最も古い待機中リクエストを許可 |
| `d` | `ecc-answer-deny` | 最も古い待機中リクエストを拒否 |
| `1`–`4` | `ecc-answer-option-N` | 選択肢 N を選んで応答 |
| `n` | `ecc-next-attention` | 応答待ちのセッションへ切り替え |
| `N` | `ecc-next-attention-in-project` | 現在のプロジェクト内で応答待ちのセッションへ切り替え |
| `b` | `ecc-dashboard` | セッションダッシュボードを開く |
| `D` | `ecc-review` | セッション中の変更すべてを 1 つの diff として開く |
| `h` | `ecc-history-open` | 過去の会話を開く |
| `U` | `ecc-usage` | 使用量と上限を表示 |
| `?` | `ecc-menu` | コマンドメニューを開く |

### セッションバッファ内

| キー | 操作 |
| --- | --- |
| `C-c C-c` | プロンプトを送信 |
| `S-RET` | 改行を挿入 |
| `TAB` | プロンプト内での補完、履歴部分での折りたたみ／展開 |
| `C-c C-a` / `C-c C-d` | ツールの実行を許可 / 拒否 |
| `C-c ?` | コマンドメニューを開く |

プロンプト領域やトランスクリプト固有のキーバインドは
[プロンプトとトランスクリプト](https://wakamenod.github.io/emacs-claude-code/ja/features/prompt/) を、
任意のバッファから利用できるグローバルキーバインドは
[キーバインド一覧](https://wakamenod.github.io/emacs-claude-code/ja/reference/key-bindings/) を参照してください。

## 謝辞

ecc は、以下のプロジェクトの設計やアプローチから着想を得ています：

* **[claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)** — IDE 側における CLI 統合パターンの設計。
* **[claude-code.el](https://github.com/stevemolitor/claude-code.el)** — Emacs におけるターミナルバッファの操作性向上。
* **[eca-emacs](https://github.com/editor-code-assistant/eca-emacs)** — バッファベースのチャット描画とインラインオーバーレイの構造。
* **[emacs-gravity](https://github.com/gdanov/emacs-gravity)** — 構造化ツリーナビゲーション、プランレビュー、承認ワークフロー。

## 他プロジェクトとの比較

Claude Code 向け Emacs パッケージの比較：

| プロジェクト | 通信プロトコル / 経路 | UI 形式 | 外部依存パッケージ | 必要 Emacs バージョン | 入手先 |
| --- | --- | --- | --- | --- | --- |
| [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el) | CLI TUI + WebSocket MCP サーバー | ターミナルエミュレータ | `websocket`, `transient`, `web-server` | 28.1 | MELPA |
| [claude-code.el](https://github.com/stevemolitor/claude-code.el) | CLI TUI | ターミナルエミュレータ | `transient`, `inheritenv` | 30 | MELPA |
| [eca-emacs](https://github.com/editor-code-assistant/eca-emacs) | 独立した `eca` バイナリとの JSON-RPC | Markdown バッファ + オーバーレイ | `dash`, `s`, `f`, `markdown-mode`, `compat`, `eca` | 28.1 | MELPA |
| [emacs-gravity](https://github.com/gdanov/emacs-gravity) | プラグインフック + Node シム + ソケット | Magit-section ツリー | `magit-section`, `transient`, Node.js | 27.1 | GitHub |
| **ecc** | ヘッドレス `claude` とのパイプ経由 stream-json | 標準バッファ（履歴 + プロンプト） | なし | 29.1 | GitHub |

### 設計上の特徴

* **claude-code-ide.el:** ターミナルバッファ内でネイティブ TUI を保持しつつ、IDE 側の完全な MCP 統合を提供。
* **claude-code.el:** ネイティブ CLI TUI を Emacs のターミナルバッファ内で直接動作させる軽量ラッパー。
* **eca-emacs:** 外部サーバーバイナリに依存し、特定のベンダーに固定されない設計。
* **emacs-gravity:** プラグインフックを用いて Emacs、tmux、システムトレイを横断し、外部セッションまで捉える高度な統合。
* **ecc:** ターミナルエミュレータを使用せず、CLI ストリームを直接標準の編集可能な Emacs テキストバッファに変換。

## ライセンス

GPL-3.0-or-later。[LICENSE](LICENSE) を参照してください。
