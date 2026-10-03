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

`M-x ecc-start` は autoload されるので、設定なしでも動きます。グローバルキーマップをプレフィクスに割り当ててください。

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map))
```

`ecc-global-map` で、リクエストへの応答、応答待ちのセッションへの移動、ダッシュボードの表示をどのバッファからでもできます。このサイトではキーを `C-c c` で書いています。[キーバインド](/emacs-claude-code/ja/reference/key-bindings/)を参照してください。

## MCP サーバーの有効化

内蔵の MCP サーバーはループバックインターフェイスで動きます。Claude は Emacs から `xref` の参照、`imenu` のシンボル、診断を読み、[レビューで作業し](/emacs-claude-code/ja/features/review-claude/)、[作業を worktree のセッションに引き渡せます](/emacs-claude-code/ja/features/spaces/#作業を-worktree-のセッションに引き渡す)。デフォルトでは無効で、Elisp の評価はさらに別に有効にします。

```elisp
(setq ecc-mcp-enabled t)
;; Claude に任意の Elisp を評価させたい場合のみ有効化:
;; (setq ecc-mcp-enable-execute-code t)
```

## 動作確認

プロジェクトのファイルを開いて `M-x ecc-start` を実行し、下のプロンプト領域にメッセージを入力して `C-c C-c` を押します。続きは[最初のセッション](/emacs-claude-code/ja/start/first-session/)にあります。

CLI が起動しないときは、`M-x ecc-show-log`（`C-c ?` → `L`）で、ecc が実行したコマンドと CLI が返したものを確認できます。

すべての設定は `M-x customize-group RET ecc` と[設定のページ](/emacs-claude-code/ja/reference/configuration/)にあります。
