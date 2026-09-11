---
title: 設定リファレンス
description: ecc の設定項目を、何を決めるものかで分類して全件掲載します。
sidebar:
  order: 2
---

ecc の `defcustom` を、既定値と何を決めるものかとあわせて全件掲載します。
すべて `ecc` カスタマイズグループにあります。

```
M-x customize-group RET ecc
```

## 設定であるもの、ないもの

ecc で `defcustom` になるのは、利用者が選ぶものだけです。好み、マシンごとの差
（フォント、画面、`PATH`）、あるいは安全性とコストについての判断。全部で 30 個
あり、以下がその全件です。

それ以外はすべて素の `defvar` です。CLI が上書きする仮の値、モデルに送る文言、
CLI 自身の癖をまとめた表、内部定数など。これらも `setq` で届きますし、テストで
束縛することもできます。`customize` に出てこない変数は、変更できない変数では
ありません。よく使うものは[このページの末尾](#設定ではないが知っておくとよい変数)
に挙げてあります。

## CLI とセッション

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-executable` | `"claude"` | Claude Code CLI の実行ファイル名、またはそのパス |
| `ecc-permission-mode` | `nil` | `--permission-mode` に渡す初期モード。`nil` は CLI の既定値のまま。ほかに `"default"`、`"acceptEdits"`、`"plan"`、`"auto"`、`"bypassPermissions"` |
| `ecc-plan-default-mode` | `"acceptEdits"` | モードを選ばずにプランを承認したとき、切り替え先になる権限モード。`nil` は変更を求めずに承認し、CLI は既定のモードでプランモードを抜ける |
| `ecc-prompt-suggestions-enabled` | `nil` | 非 nil で `--prompt-suggestions` を渡す |
| `ecc-command-wrapper-function` | `nil` | CLI のコマンドラインを実行前に書き換える関数。コマンドのリストとプロジェクトルートで呼ばれ、実行するコマンドのリストを返す。`nil` ならそのまま実行する |

**モデルを指定する設定はあえて用意していません。**新しいセッションのモデルは
Claude Code の設定から、再開したセッションのモデルはその記録の最後の実アシス
タントメッセージから決まります。`--model` を渡すとそれを恒久的に上書きしてしま
い、それまでの `/model` をすべて帳消しにします。動いているセッションのモデルを
変えるには `ecc-set-model` を使ってください。

同じ理由で予算の設定もありません。コストは Claude Code 側の設定に属します。

## トランスクリプト

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-chat-text-width` | `100` | テキストを描画する最大桁数。`nil` ならウィンドウ幅いっぱい。余った幅はウィンドウから差し引くのではなく右マージンに回すので、そのウィンドウにある他のものには影響しない |
| `ecc-chat-line-spacing` | `0.15` | 各行の下に入れる余白。`line-spacing` と同じ読み方で、浮動小数は行高に対する割合。`nil` で余白なし |
| `ecc-render-result-max-lines` | `12` | 表示するツール結果の行数。全文はいつでも `RET` で見られる |
| `ecc-render-diff-max-lines` | `40` | ツールや権限のセクション内に表示する diff の行数。全文はいつでも `RET` で見られる |
| `ecc-diff-context-lines` | `3` | トランスクリプト内で変更の前後に表示する文脈行数 |
| `ecc-review-context-lines` | `3` | レビューが自前で作る diff で、変更の前後につける文脈行数 |
| `ecc-stream-throttle` | `0.05` | ストリーミングの差分をまとめてから描画するまでの秒数。0 なら届いた差分をそのつど描画する |
| `ecc-render-debounce` | `0.1` | 変更をまとめてからライブ領域を再描画するまでの秒数 |

## ヘッダーラインとモードライン

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-hint-context-indicator` | `t` | 非 nil でセッションのヘッダーラインに残りコンテキストを表示する |
| `ecc-prompt-suggestion-display` | `t` | 非 nil でプロンプト領域に CLI からの提案を表示する。提案が届くのは `--prompt-suggestions` 付きで開始したセッションだけで、それを決めるのは `ecc-prompt-suggestions-enabled` |
| `ecc-mode-line-format` | `nil` | セッションがモードラインで自分をどう名乗るか。`nil` は何も表示しない |

`ecc-mode-line-format` の既定値が `nil` なのは、モードラインが狭く、同じ数値が
すでにヘッダーラインにあり、両方に繰り返すセッションは読めたものではなかったか
らです。それでも表示したい場合は書式文字列を取ります。

| 指定子 | 意味 |
|---|---|
| `%n` | セッション名 |
| `%m` | モデル |
| `%p` | 権限モード |
| `%l` | 残りコンテキスト（パーセント） |
| `%t` | コンテキスト中のトークン数 |
| `%c` | ここまでのコスト |
| `%r` | レート制限の使用率 |
| `%s` | 状態 |

## 通知

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-notify-level` | `'message` | イベントがどれだけ騒ぐか。`message` はエコーエリアに 1 行、`pulse` はさらにトランスクリプトを光らせ、`desktop` はデスクトップ通知も出す。`nil` は何も言わない |
| `ecc-notify-events` | `'(turn-finished request exited)` | 通知するイベント。ターンの完了、回答待ちのリクエスト、ひとりでに停止したセッション |
| `ecc-notify-suppress-when-focused` | `t` | 非 nil なら Emacs にフォーカスがある間はデスクトップ通知を抑える |
| `ecc-notify-sound` | `nil` | デスクトップ通知が鳴らす音の名前。`nil` なら無音。macOS では `"Glass"` のようなシステムサウンド名 |
| `ecc-notify-function` | `#'ecc-notify-default` | SESSION、EVENT、TEXT を受け取って呼ばれる関数。差し替えると通知を完全に引き取る |

## ウィンドウ

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-window-large-frame-min-height` | `80` | 3 つめのセッションウィンドウを置くのにフレームが必要な高さ（行数）。これを下回ると、セッションは 2 つのウィンドウを分け合い、残りはタブラインで届かせる |
| `ecc-window-sub-height` | `0.33` | 3 つめのセッションウィンドウの高さ。割合または行数。他の 2 つがある側からではなく、フレームの主要領域（たいていはソースコード）から取る |

`ecc-window-large-frame-min-height` の既定値はノート PC と大画面を見分けるため
のものです。14 インチの画面はおよそ 58 行、16 インチはおよそ 67 行、これを測っ
たディスプレイは 114 行入ります。

## 脇に表示されるバッファ

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-btw-display` | `'window` | `/btw` の脇質問への回答をどこに表示するか |
| `ecc-usage-display` | `'window` | `ecc-usage` が調べた結果をどこに表示するか |

どちらも `window` か `posframe` を取ります。`posframe` はバッファをフレームの上
に浮かべるもので、[posframe](https://github.com/tumashu/posframe) パッケージと
グラフィカルフレームが要ります。どちらか欠けていればウィンドウが使われ、バッ
ファは同じものです。

## MCP サーバー

ecc はループバックインターフェイスで MCP サーバーを動かし、各セッションに登録
できます。これにより Claude は Emacs だけが知っていること、すなわち xref、
imenu、tree-sitter、project、診断情報を尋ねられるようになります。

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-mcp-enabled` | `nil` | 非 nil で、開始するすべてのセッションにサーバーを登録する。サーバーは最初に必要になったセッションで起動し、`ecc-mcp-stop` で停止する |
| `ecc-mcp-enable-execute-code` | `nil` | 非 nil で、任意の Elisp を評価するツールを公開する |
| `ecc-mcp-excluded-tools` | `nil` | 何が登録したかによらず公開しないツールの名前。体感できるほど時間のかかるツールはここに入れる |

:::caution[これは 2 つの別々の判断です]
`ecc-mcp-enable-execute-code` は `ecc-mcp-enabled` からあえて導かれません。この
ツールを通してモデルが書いたものは、この Emacs の権限で実行されます。ですから
サーバーを立てることと、Elisp の評価を許すことは別々に尋ねられます。
:::

## ログ

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-log-max-lines` | `5000` | セッションログバッファに保持する最大行数。`nil` ならすべての行を保持する |
| `ecc-debug` | `nil` | 非 nil で、生のプロトコル行に加えて内部の診断情報も記録する |

`ecc-show-log` は、現在のバッファが結びついているセッションの生プロトコルログを
開きます。ディスパッチの失敗は決して握りつぶされません。ログと、トランスクリプ
ト中の `unknown` ノードの両方に残ります。

## 設定ではないが知っておくとよい変数

以下は `defvar` なので `customize` には出てきません。`setq` してください。

| 変数 | 既定値 | 何を決めるか |
|---|---|---|
| `ecc-chat-return-sends` | `nil` | `nil`: `RET` は改行を入れ、`C-c C-c` が送信する。`t`: ターミナルクライアントと同じく `RET` が送信する |
| `ecc-disabled-plugins` | `nil` | ecc が開始するセッションで無効にする `"name@marketplace"` の一覧。セッション単位なので、自分の対話セッションには影響しない |
