---
title: インストール
description: ecc に必要なもの、リポジトリからの入れ方、そして初日に決めておく価値のある設定。
sidebar:
  order: 2
---

## 必要なもの

- **Emacs 29.1 以降。** このバージョンなら `transient` は同梱で、ecc は外部パッ
  ケージを一つも要求しません。
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)。** `PATH` に
  あるか、`ecc-executable` で場所を指定してください。

必須はこれだけです。以下は任意で、無くても ecc は動きます。

| パッケージ | 加わるもの |
|---|---|
| [ghostel](https://github.com/dakra/ghostel) | `ecc-tui-open` がセッションを渡す先のターミナル |
| [posframe](https://github.com/tumashu/posframe) | `/btw` の回答と使用量レポートのポップアップ |
| [nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) | トランスクリプトのツールごとのアイコン |
| [markdown-mode](https://github.com/jrblevin/markdown-mode) | プランバッファとレビューバッファのメジャーモード |

## 入れる

ecc は MELPA にはありません。リポジトリから直接入れてください。

リポジトリ名は `emacs-claude-code`、パッケージ名は `ecc` です。リポジトリ名から
パッケージ名を推測するレシピには、明示的に教える必要があります。

### Emacs 30 以降

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

`:rev "<commit-sha>"` にすれば、ブランチを追わず特定のコミットに固定できます。

### Emacs 29

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

その後は `:vc` の無い普通の `use-package` で設定します。

### straight.el と Elpaca

```elisp
;; straight.el
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))

;; Elpaca
(use-package ecc
  :ensure (ecc :host github :repo "wakamenod/emacs-claude-code"))
```

### 手でクローンする

```sh
git clone https://github.com/wakamenod/emacs-claude-code \
  ~/.emacs.d/site-lisp/emacs-claude-code
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/emacs-claude-code")
(require 'ecc)
```

## 最初の設定

`M-x ecc-start` は autoload なので、設定ゼロでも ecc は動きます。それでも初日に
決めておく価値のあるものが二つあります。

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  ;; `ecc-global-map' はプレフィックスキーマップ。権限に答える、待っている
  ;; セッションに飛ぶ、ダッシュボードを開く -- どのバッファからでも。
  ;; `:bind-keymap' は、プレフィックスが初めて押されるまで ecc の読み込みを
  ;; 遅らせます。
  :bind-keymap ("C-c c" . ecc-global-map)
  :bind ("C-c C-v" . ecc-start)
  :config
  (setq ecc-chat-text-width 100)   ; トランスクリプトの幅（桁数）
  (setq ecc-notify-level 'pulse)   ; nil, `message', `pulse', `desktop'
  (setq ecc-permission-mode nil)   ; nil は CLI 側の既定をそのままにする

  ;; t にするとターミナルクライアントと同じく RET が送信になります。
  ;; nil（既定）なら RET は改行で、送信は C-c C-c です。
  (setq ecc-chat-return-sends nil))
```

効くのはキーマップのほうです。セッションはあなたの一言が要るその瞬間に止まりま
す。`ecc-global-map` は、どのセッションだったかを探しに行かずに答えるためのもの
です。

:::note[モデルは設定項目ではありません]
モデルを名指しする変数は、意図的にありません。新しいセッションは Claude Code の
設定からモデルを取り、再開したセッションは記録の最後にあるモデルを引き継ぎます。
`--model` を渡すとそのどちらも恒久的に上書きしてしまい、それ以降の `/model` を
すべて無かったことにします。動いているセッションのモデルを変えるには
`ecc-set-model` を使ってください。コストについても同じで、これは ecc ではなく
Claude Code の設定の話です。
:::

## MCP サーバーを有効にする

ループバックの MCP サーバーは、Emacs にしか分からないことを Claude が訊けるよう
にします。`xref` が見つける参照、`imenu` が並べるシンボル、`flymake` が持つ診断
です。自分で有効にするまで止まっていますし、Elisp の評価にはもう一段の有効化が
要ります。

```elisp
(setq ecc-mcp-enabled t)
;; Claude に Elisp を評価させたい場合だけ:
;; (setq ecc-mcp-enable-execute-code t)
```

## 動いているか確かめる

1. プロジェクトの中のファイルを開く。
2. `M-x ecc-start`。
3. 下のプロンプト領域に何か書いて `C-c C-c`。

CLI が起動できないときは、セッションのログバッファ（`C-c ?` から `L`、または
`M-x ecc-show-log`）に、実行したコマンドラインとパイプから返ってきたものが全部
入っています。

他の設定はすべて `M-x customize-group RET ecc` と
[設定リファレンス](/emacs-claude-code/ja/reference/configuration/)にあります。
次は[最初のセッション](/emacs-claude-code/ja/start/first-session/)へ。
