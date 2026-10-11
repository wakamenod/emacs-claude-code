---
title: インストール
description: 動作要件、インストール手順、おすすめの初期設定。
sidebar:
  order: 1
---

## 動作要件

- **Emacs 29.1 以降。** ほかのパッケージは要りません。`transient` は Emacs に含まれています。
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)。** `PATH` に置くか、`ecc-executable` で指定します。

次のパッケージは任意です。

| パッケージ | 機能 |
|---|---|
| [ghostel](https://github.com/dakra/ghostel) | `ecc-tui-open` でセッションを引き渡すターミナルエミュレータ |
| [posframe](https://github.com/tumashu/posframe) | `/btw` の回答や使用量レポートのフローティングポップアップ |
| [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) | トランスクリプト内のツール呼び出しアイコン |
| [markdown-mode](https://github.com/jrblevin/markdown-mode) | プランバッファおよびレビューバッファのメジャーモード |

## インストール手順

ecc は MELPA にないので、Git リポジトリからインストールします。リポジトリは `emacs-claude-code`、パッケージは `ecc` なので、URL から名前を取るパッケージマネージャーにはパッケージ名を指定してください。

### Emacs 30 以降

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

`:rev "<commit-sha>"` でコミットを固定できます。

### Emacs 29

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

そのあとは `:vc` なしの `use-package` で設定します。

### straight.el

```elisp
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))
```

## 最初の設定

`M-x ecc-start` は autoload されるので、設定なしでも動きます。次の設定は、グローバルキーマップをプレフィクスに割り当て、いくつかのデフォルトを変えます。

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map)
  :custom
  ;; auto モードでセッションを始める。ほとんどのリクエストに CLI が自分で答える。
  (ecc-permission-mode "auto")
  ;; エコーエリアへの表示に加えて、トランスクリプトを光らせる。
  (ecc-notify-level 'pulse)
  ;; 使用量レポートと /btw の回答をフレームの上に浮かべる (posframe が必要)。
  (ecc-usage-display 'posframe)
  (ecc-btw-display 'posframe)
  ;; レビューを 1 つの diff-mode バッファではなく ediff で開く。
  (ecc-review-style 'ediff)
  ;; すべてのセッションに Emacs の MCP サーバーを登録する。
  (ecc-mcp-enabled t)
  ;; ターンのあとに CLI が次のプロンプトを提案する。
  (ecc-prompt-suggestions-enabled t))
```

`ecc-global-map` で、リクエストへの応答、応答待ちのセッションへの移動、ダッシュボードの表示をどのバッファからでもできます。このサイトではキーを `C-c c` で書いています。[キーバインド](/emacs-claude-code/ja/reference/key-bindings/)を参照してください。

どの設定も省けます。

- `ecc-permission-mode` がなければ、セッションは CLI のデフォルトのモードで始まり、Claude がファイルを編集する前やコマンドを実行する前に確認を求めます。実行中のセッションのモードは `S-TAB` で変わります。[権限モード](/emacs-claude-code/ja/features/permissions/#権限モード)を参照してください。
- `posframe` での表示には [posframe](https://github.com/tumashu/posframe) パッケージとグラフィカルなフレームが必要です。どちらかがなければウィンドウを使います。
- `ecc-review-style` のデフォルトは `'diff` で、1 つの `diff-mode` バッファです。`'ediff` では各ファイルの 2 つの側を並べます。[ediff でのレビュー](/emacs-claude-code/ja/features/review-ediff/)を参照してください。
- `ecc-mcp-enabled` は次の節で説明します。
- 提案されたプロンプトは空のプロンプト領域に出て、`C-c C-s` で取り込めます。[提案](/emacs-claude-code/ja/features/prompt/#提案)を参照してください。

[corfu](https://github.com/minad/corfu) を使っているなら、セッションバッファで有効にすると、スラッシュコマンドと `@` 参照の補完が corfu のポップアップに出ます。

```elisp
(add-hook 'ecc-chat-mode-hook #'corfu-mode)
```

## MCP サーバーの有効化

内蔵の MCP サーバーはループバックインターフェイスで動きます。Claude は Emacs から `xref` の参照、`imenu` のシンボル、診断を読み、[レビューで作業し](/emacs-claude-code/ja/features/review-claude/)、[作業を worktree のセッションに引き渡せます](/emacs-claude-code/ja/features/spaces/#作業を-worktree-のセッションに引き渡す)。デフォルトでは無効で、上の設定の `(ecc-mcp-enabled t)` で有効になります。Elisp の評価はさらに別に有効にします。

```elisp
;; Claude に任意の Elisp を評価させたい場合のみ有効化:
;; (setq ecc-mcp-enable-execute-code t)
```

## 動作確認

プロジェクトのファイルを開いて `M-x ecc-start` を実行し、下のプロンプト領域にメッセージを入力して `C-c C-c` を押します。続きは[最初のセッション](/emacs-claude-code/ja/start/first-session/)にあります。

CLI が起動しないときは、`M-x ecc-show-log`（`C-c ?` → `L`）で、ecc が実行したコマンドと CLI が返したものを確認できます。

すべての設定は `M-x customize-group RET ecc` と[設定のページ](/emacs-claude-code/ja/reference/configuration/)にあります。
