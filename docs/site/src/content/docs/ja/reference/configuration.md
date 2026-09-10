---
title: 設定リファレンス
description: ecc の設定項目と、ここに載っていないものへの辿り方。
sidebar:
  order: 1
---

:::caution[未完成]
ecc の `defcustom` は 30 個あります。以下に挙げているのはその一部で、残りはこれから
書きます。それまでは `M-x customize-group RET ecc` が完全な一覧で、各項目の
docstring も読めます。
:::

## すべての設定に辿り着く

```
M-x customize-group RET ecc
```

ecc で `defcustom` にするのは、ユーザーが選ぶもの — 好み、マシンごとの違い、
安全性やコストの判断 — に限っています。それ以外はただの `defvar` で、`setq` で届き
テストで束縛もできます。つまり `customize` に出てこない変数は、変えられない変数では
ありません。

## 主な設定

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-executable` | `"claude"` | Claude Code CLI の名前、またはパス |
| `ecc-chat-text-width` | `100` | transcript を描く桁数。余った幅は右マージンになる |
| `ecc-notify-level` | `'message` | `nil`, `'message`, `'pulse`, `'desktop` |
| `ecc-permission-mode` | `nil` | 起動時の `--permission-mode`。`nil` なら CLI の既定のまま |
| `ecc-mcp-enabled` | `nil` | ループバックの MCP サーバーを各セッションに登録するか |
| `ecc-mcp-enable-execute-code` | `nil` | Elisp を評価するツールを公開するか — これは別個の判断 |

## defcustom ではないが知っておくとよいもの

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-chat-return-sends` | `nil` | `nil`: `RET` は改行、送信は `C-c C-c`。`t`: ターミナルのクライアントと同じく `RET` で送信 |
| `ecc-disabled-plugins` | `nil` | ecc が起動するセッションで無効にする `"name@marketplace"` の一覧 |
