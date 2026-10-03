---
title: インストール
description: 動作要件、インストール手順、おすすめの初期設定。
sidebar:
  order: 2
---

## 動作要件

- **Emacs 29.1 以降。** `transient` は Emacs 29.1 以降に同梱されており、ほかに必要な外部パッケージはありません。
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)。** `PATH` の通った場所に置くか、`ecc-executable` で指定します。

必須なのはこの2 つだけです。次のパッケージは任意です:

| パッケージ | 機能 |
|---|---|
| [ghostel](https://github.com/dakra/ghostel) | `ecc-tui-open` でセッションを引き渡すターミナルエミュレータ |
| [posframe](https://github.com/tumashu/posframe) | `/btw` の回答や使用量レポートのフローティングポップアップ |
| [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) | トランスクリプト内のツール呼び出しアイコン |
| [markdown-mode](https://github.com/jrblevin/markdown-mode) | プランバッファおよびレビューバッファのメジャーモード |

## インストール手順

ecc は現在 MELPA に登録されていません。Git リポジトリから直接インストールしてください。

リポジトリ名は `emacs-claude-code`、パッケージ名は `ecc` です。リポジトリ名からパッケージ名を自動推測するパッケージマネージャーでは、パッケージ名を明示的に指定する必要があります。

### Emacs 30 以降

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

最新を追いかけずに特定のコミットに固定するには、`:rev "<commit-sha>"` を指定します。

### Emacs 29

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

そのあとは、通常の `use-package` 宣言（`:vc` なし）で設定します。

### straight.el

```elisp
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))
```

## 最初の設定

`M-x ecc-start` は autoload されるので、設定を書かなくても動きます。最初に入れておくと便利なのは、グローバルキーマップの割り当てです:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map))
```

`ecc-global-map` があれば、権限の確認への応答、待機中のセッションへの移動、ダッシュボードの表示をどのバッファからでもできます。止まっているセッションを探し回る必要はありません。すべてのキーは[キーバインド一覧](/emacs-claude-code/ja/reference/key-bindings/)にあります。

## MCP サーバーの有効化

内蔵のループバック MCP サーバーを使うと、Claude は Emacs にエディタの情報（`xref` の参照、`imenu` のシンボル、`flymake` の診断）を問い合わせられます。また、Claude が[作業を専用の worktree のセッションに引き渡す](/emacs-claude-code/ja/features/spaces/#作業を-worktree-のセッションに引き渡す)こともできます。デフォルトでは無効です。任意の Elisp の評価は、さらに別の設定で明示的に許可する必要があります:

```elisp
(setq ecc-mcp-enabled t)
;; Claude に任意の Elisp を評価させたい場合のみ有効化:
;; (setq ecc-mcp-enable-execute-code t)
```

## 動作確認

1. プロジェクト内の任意のファイルを開きます。
2. `M-x ecc-start` を実行します。
3. 下部のプロンプト領域にメッセージを入力し、`C-c C-c` を押します。

CLI が起動しない場合は、セッションのログバッファ（`C-c ?` のあと `L`、または `M-x ecc-show-log`）を確認してください。実際に実行したコマンドと、CLI プロセスから受け取った生の出力が記録されています。

そのほかの設定は、`M-x customize-group RET ecc` か[設定リファレンス](/emacs-claude-code/ja/reference/configuration/)で確認できます。セッション内で `C-c ?` を押すと Transient メニューが開き、すべてのコマンドとそのキーが表示されます。
