---
title: 概要
description: ecc が何をするか、手短に。
sidebar:
  order: 1
---

ecc は `claude` をヘッドレスで動かし、その stream-json プロトコルでパイプ越しに
やりとりし、会話を普通の Emacs バッファに描きます。ターミナルエミュレータは使い
ません。

セッションバッファは、上にトランスクリプト、区切り線の下に入力するプロンプトを
持ちます。トランスクリプトは読み取り専用のテキストなので、`isearch`、`occur`、
narrowing、`M-w` が他の場所と同じように効きます。ここには何も入力しないので、一
文字がそのまま操作になります（`n`、`p`、`TAB`、`a`、`d`）。プロンプト領域では、
文字は文字のままです。

始める前に知っておくとよいこと:

- **権限プロンプトの既定は拒否です。** セッション内なら `C-c C-a` /
  `C-c C-d`、`ecc-global-map` を束縛すればどのバッファからでも答えられます。
- **必要なのは Emacs 29.1 と `claude` CLI だけです。** 外部パッケージは要りませ
  ん。
- **CLI 本来のインターフェースが要るときは `ecc-tui-open`** が本物のターミナルク
  ライアントにセッションを渡し、`ecc-tui-return` が引き取ります。

[インストール](/emacs-claude-code/ja/start/installation/)して、
[セッションを一つ通してみて](/emacs-claude-code/ja/start/first-session/)ください。
