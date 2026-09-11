---
title: インストール
description: 動作要件、リポジトリからのインストール手順、および推奨される初期設定。
sidebar:
  order: 2
---

## 動作要件

- **Emacs 29.1 以降** (`transient` は Emacs 29.1+ に同梱されています。必須の外部パッケージはありません)
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** (`PATH` が通っているか、`ecc-executable` で実行可能ファイルのパスが指定されていること)

必須要件は上記のみです。以下のパッケージは任意で、導入されている場合に機能が拡張されます:

| パッケージ | 機能 |
|---|---|
| [ghostel](https://github.com/dakra/ghostel) | `ecc-tui-open` でセッションを引き渡すターミナルエミュレータ |
| [posframe](https://github.com/tumashu/posframe) | `/btw` の回答や使用量レポートのフローティングポップアップ |
| [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) | トランスクリプト内のツール呼び出しアイコン |
| [markdown-mode](https://github.com/jrblevin/markdown-mode) | プランバッファおよびレビューバッファのメジャーモード |

## インストール手順

ecc は現在 MELPA に登録されていません。Git リポジトリから直接インストールしてください。

リポジトリ名は `emacs-claude-code`、パッケージ名は `ecc` です。リポジトリ名からパッケージ名を自動推測するパッケージマネージャーでは、パッケージ名を明示的に指定する必要があります。

### Emacs 30 以降 (`use-package` と `:vc`)

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

特定のコミットに固定したい場合は、`:rev "<commit-sha>"` を指定してください。

### Emacs 29 (`package-vc-install`)

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

インストール後は、通常の `use-package` 宣言（`:vc` なし）で設定できます。

### straight.el

```elisp
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))
```

## 推奨される初期設定

`M-x ecc-start` は autoload に設定されているため、追加設定なしでもすぐに動作します。最も実用的な設定は、グローバルキーマップの割り当てです:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  :bind-keymap ("C-c c" . ecc-global-map))
```

`ecc-global-map` を割り当てておくと、権限リクエストへの応答、待機中セッションへのジャンプ、ダッシュボードの表示をどのバッファからでも実行できます（作業中のバッファから離れてセッションを探しにいく必要がなくなります）。詳細は[キーバインド一覧](/emacs-claude-code/ja/reference/key-bindings/)をご覧ください。

## MCP サーバーの有効化

内蔵のループバック MCP サーバーを有効にすると、Claude から Emacs の編集コンテキスト（`xref` の参照検索、`imenu` のシンボル一覧、`flymake` の診断情報など）を直接照会できるようになります。デフォルトでは無効になっており、任意の Elisp を評価させる機能はセキュリティのため別途明示的な許可が必要です:

```elisp
(setq ecc-mcp-enabled t)
;; Claude に任意の Elisp を評価させたい場合のみ有効化:
;; (setq ecc-mcp-enable-execute-code t)
```

## 動作確認

1. プロジェクト内の任意のファイルを開きます。
2. `M-x ecc-start` を実行します。
3. 下部のプロンプト領域に質問などを入力し、`C-c C-c` を押して送信します。

CLI が起動しない場合は、セッションログバッファ（`C-c ?` を押してから `L`、または `M-x ecc-show-log`）を確認してください。実際に実行されたコマンドラインと、CLI プロセスから返ってきた標準出力/標準エラー出力が記録されています。

その他の詳細なカスタマイズ項目は、`M-x customize-group RET ecc` または[設定リファレンス](/emacs-claude-code/ja/reference/configuration/)をご確認ください。セッション内で `C-c ?` を押すと、利用可能な全コマンドとキーが一覧表示される Transient メニューが開きます。
