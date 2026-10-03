---
title: 設定
description: ecc のすべてのカスタマイズ項目と変数のリファレンス。
sidebar:
  order: 2
---

このページには、ecc のすべての `defcustom` を分野ごとに載せています。どの設定も `ecc` カスタマイズグループに属します:

```
M-x customize-group RET ecc
```

## CLI とセッション

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-executable` | `"claude"` | Claude Code CLI の実行可能ファイル名、またはそのフルパス |
| `ecc-permission-mode` | `nil` | `--permission-mode` で渡す最初のモード。`nil` なら CLI のデフォルトのまま。指定できる値: `"default"`, `"acceptEdits"`, `"plan"`, `"auto"`, `"bypassPermissions"` |
| `ecc-plan-default-mode` | `"acceptEdits"` | モードを選ばずにプランを承認したときに切り替える権限モード。`nil` ならモードの変更を求めずに承認し、CLI はデフォルトモードに戻る |
| `ecc-prompt-suggestions-enabled` | `nil` | 非 nil なら、CLI に `--prompt-suggestions` を渡して次のプロンプトの提案を有効にする |
| `ecc-command-wrapper-function` | `nil` | CLI を起動する直前にコマンドを書き換える関数。`(command-list project-root)` を受け取り、書き換えたコマンドのリストを返す。`nil` ならそのまま実行する |
| `ecc-disabled-plugins` | `nil` | ecc が開始するセッションで無効にするプラグインの識別子（`"name@marketplace"`）のリスト。セッションごとに適用されるので、ターミナルクライアントではプラグインは有効のまま |

デフォルトのモデルを決める設定は、あえて用意していません。新しいセッションのモデルは Claude Code の設定で、再開したセッションのモデルは最後のアシスタントのターンで決まります。`--model` を常に渡すと、ユーザーの選択をずっと上書きし、セッション中に `/model` で変えた分も元に戻してしまいます。実行中のセッションのモデルを変えるには、`ecc-set-model`（メニューの `m`）を使ってください。

同じ理由で、セッションのコストの上限を決める設定もありません。上限は Claude Code の設定で決めます。

## トランスクリプト

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-chat-return-sends` | `nil` | `nil`（デフォルト）なら、`RET` で改行し、`C-c C-c` で送信する。`t` なら、ターミナルクライアントと同じく `RET` ですぐに送信する |
| `ecc-chat-text-width` | `100` | テキストを描画する最大の桁数。`nil` ならウィンドウの幅いっぱいに描画する。余った幅は右マージンになるので、隣のウィンドウの配置には影響しない |
| `ecc-chat-line-spacing` | `0.15` | 各行の下に足す行間。Emacs 標準の `line-spacing` と同じ解釈（浮動小数点数は行の高さに対する比率）。`nil` なら足さない |
| `ecc-render-result-max-lines` | `12` | ツールの結果のプレビューに表示する最大行数。全文はいつでも `RET` で見られる |
| `ecc-render-inhibit-inline-diff` | `nil` | `nil`（デフォルト）なら、ファイルを変更する呼び出し（Edit・MultiEdit・Write・NotebookEdit と、CLI がファイルの変更を報告した Bash）は diff を開いた状態で表示する。`t` なら折りたたんで表示し、`TAB` で開く |
| `ecc-render-diff-max-lines` | `40` | ツールと権限のブロックにインラインで表示する diff の最大行数。全文はいつでも `RET` で見られる |
| `ecc-diff-context-lines` | `3` | トランスクリプト内の変更箇所の前後に表示する文脈行数 |
| `ecc-stream-throttle` | `0.05` | ストリーミングの差分を、再描画の前にためておく秒数。0 なら差分ごとにすぐ描画する |
| `ecc-render-debounce` | `0.1` | トランスクリプトの動いている部分を再描画するまでのデバウンスの待ち時間（秒） |
| `ecc-image-inline` | `t` | `t` ならトランスクリプトの画像を表示する。`nil` ならファイル名の行だけを表示する（この行はどちらでも表示される） |

## ヘッダーラインとモードライン

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-hint-context-indicator` | `t` | 非 nil なら、セッションのヘッダーラインにコンテキストの残りを表示する |
| `ecc-prompt-suggestion-display` | `t` | 非 nil なら、CLI からの提案をプロンプト領域にゴーストテキストで表示する。`ecc-prompt-suggestions-enabled` が必要 |
| `ecc-mode-line-format` | `nil` | モードラインにセッションの状態を表示する書式文字列。`nil` なら表示しない |

`ecc-mode-line-format` のデフォルトが `nil` なのは、モードラインの場所が限られていて、同じ数値がすでにヘッダーラインに出ているからです。表示するには、次の指定子を使います:

| 指定子 | 意味 |
|---|---|
| `%n` | セッション名 |
| `%m` | 使用中のモデル |
| `%p` | 権限モード |
| `%l` | コンテキストの残り（パーセント） |
| `%t` | コンテキストウィンドウ内のトークンの合計 |
| `%c` | 累計コスト |
| `%r` | レート制限の使用率 |
| `%s` | セッションの状態 |

## 通知

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-notify-level` | `'message` | 通知の強さ: `'message` はエコーエリアに 1 行表示、`'pulse` はそれに加えてトランスクリプトを点滅、`'desktop` は OS のデスクトップ通知、`nil` は通知しない |
| `ecc-notify-events` | `'(turn-finished request exited)` | 通知するイベントのリスト: ターンの完了、待機中のリクエスト、プロセスの終了 |
| `ecc-notify-suppress-when-focused` | `t` | 非 nil なら、Emacs にフォーカスがある間はデスクトップ通知を出さない |
| `ecc-notify-sound` | `nil` | デスクトップ通知時に再生するシステムサウンド名（macOS では `"Glass"` など）。`nil` で無音 |
| `ecc-notify-function` | `#'ecc-notify-default` | `(SESSION EVENT TEXT)` を引数に呼ばれる通知関数。変えるとデフォルトの通知処理をすべて置き換える |

## レビュー

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-review-style` | `'diff` | `ecc-review` と `ecc-review-range` の変更の表示方法。`'diff` は読み取り専用の `diff-mode` バッファ 1 つを使い、`'ediff` はレビューするすべてのファイルを 1 つの ediff セッションで左右に並べる。どちらも読み取り専用で、送るプロンプトも同じ |
| `ecc-review-menu-count-session-changes` | `t` | non-nil なら、レビューのメニュー（`C-c c D`）に、セッション開始以降に変更されたファイルの数を表示する。数えるには作業ツリーのスナップショットが必要で、300 ファイルのリポジトリで約 35 ms、20,000 ファイルで約 70 ms かかる。メニューが開くのが遅いときは `nil` にする |
| `ecc-review-auto-refresh` | `t` | non-nil なら、開いているレビューは、そのセッションのツールの完了、ターンの終了、リポジトリのファイルの保存のたびに diff を読み直す。コメントと読んでいた位置は保たれる。見えていないレビューは表示されたときに読み直す。ediff のレビューも追従する。`nil` なら `g` のときだけ読み直す |
| `ecc-review-files-width` | `32` | `s` でレビューの横に出すファイルの一覧の幅（桁数） |
| `ecc-review-ediff-layout` | `'stacked` | ediff のレビューを開いたときの並び。`'stacked` は変更前を上・変更後を下に並べ、Claude の返答の欄を右に出す。`'side-by-side` は左右に並べ、欄を下に出す。開いたレビューでは `\|` で切り替わる |
| `ecc-review-talk-reply-width` | `75` | 上下に並べた ediff のレビューの右に出す、Claude の返答の欄の幅（桁数）。diff の幅が 80 桁を切るほどフレームが狭いときは、欄を下に出す |
| `ecc-review-talk-reply-height` | `12` | 左右に並べた ediff のレビューの下に出す、Claude の返答の欄の高さ（行数）。`nil` でどちらの並びでも欄を出さない |
| `ecc-review-talk-reply-place` | `'auto` | 返答の欄を出す場所。`'auto` は並びに合わせてレビューの横、`'frame` はレビューごとの別のフレーム。そのレビューと一緒に閉じ、フォーカスを取らない |

## ウィンドウ分割

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-window-large-frame-min-height` | `80` | 3 つ目のセッションウィンドウを開くのに必要なフレームの最小の高さ（行数）。これより低いと、セッションは 2 つのウィンドウを分け合い、タブラインで切り替える |
| `ecc-window-sub-height` | `0.33` | 3 つ目のセッションウィンドウの高さ（比率または行数）。セッションの列ではなく、フレームの主な領域（たいていはコードのバッファ）から取る |
| `ecc-tab-line-scope` | `'project` | セッションウィンドウのタブラインに並べるセッションの範囲。`'project` はそのウィンドウのプロジェクトのセッションだけ、`'all` は Emacs で開いているすべてのセッション |
| `ecc-use-spaces` | `t` | 非 nil なら、プロジェクトごとにタブバーのタブ（Space）を作り、その中のウィンドウには手を出さない。nil なら以前のレイアウトになる。トランスクリプトは、プロジェクトに割り当てた役割（main、sub-1、sub-2）を持つサイドウィンドウに表示され、タブ、サイドバー、worktree のコマンドはない。[Space と worktree](/emacs-claude-code/ja/features/spaces/) を参照 |
| `ecc-space-always-session` | `t` | `ecc-use-spaces` がオンのとき、Space に常にセッションを置くか。非 nil なら、何も動いていない Space を開くとセッションを始め、最後のセッションを閉じると Space も閉じる。nil なら、Space はソースファイルだけを表示して開き、プロジェクトの最後のバッファを kill するまで開いたまま |
| `ecc-space-session-min-width` | `80` | `ecc-use-spaces` がオンのとき、トランスクリプトの並びをさらに分割するのにセッションウィンドウが必要とする桁数。この幅の列がもう取れなければ、すべてのトランスクリプトを狭くするのではなく、いちばん長く操作していないセッションのウィンドウを使い回す。下限は `window-min-width` |
| `ecc-sidebar-width` | `28` | サイドバーの幅（桁数）。大きなフォントの 13 インチのノートと 34 インチのディスプレイでは、28 桁がフレームに占める割合が違う。プロジェクト名の長さもさまざま |

`ecc-window-large-frame-min-height` のデフォルト（80 行）は、ノート PC の画面と大きな外部ディスプレイを分ける値です。14 インチの画面はおよそ 58 行、16 インチはおよそ 67 行ですが、一般的なデスクトップのモニターでは 110 行以上表示できます。

## ポップアップおよび補助バッファ

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-btw-display` | `'window` | `/btw` のサイドクエリの表示方法（`'window` または `'posframe`） |
| `ecc-usage-display` | `'window` | `ecc-usage` のレポートの表示方法（`'window` または `'posframe`） |

どちらも `'window` または `'posframe` を指定できます。`'posframe` はバッファをフレームの上に浮かぶポップアップで表示します（[posframe](https://github.com/tumashu/posframe) パッケージとグラフィカルなフレームが必要です）。posframe が使えないときは、通常のウィンドウ分割になります。

## MCP サーバー

ecc は、ループバックインターフェイスで動くインプロセスの MCP サーバーを起動し、各セッションに登録できます。これで Claude は、Emacs にエディタの情報（`xref`、`imenu`、`tree-sitter`、プロジェクトの情報、診断）を問い合わせられます。Claude が[レビューバッファにコメントを付ける](/emacs-claude-code/ja/features/review/#claude-のコメント)こともできます。

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-mcp-enabled` | `nil` | 非 nil なら、開始するすべてのセッションに内蔵の MCP サーバーを登録する。最初に使われたときに起動し、`ecc-mcp-stop` で止まる |
| `ecc-mcp-enable-execute-code` | `nil` | 非 nil なら、Claude が任意の Elisp を評価できる MCP ツールを公開する |
| `ecc-mcp-excluded-tools` | `nil` | MCP の登録から外すツール名のリスト。目に見えて遅くなるツールに使う |

:::caution[2 つの独立した設定]
`ecc-mcp-enabled` をオンにしても、`ecc-mcp-enable-execute-code` はオンになりません。このツールで実行するコードは Emacs の中でユーザーの権限をすべて持つので、サーバーの起動とコードの実行は、それぞれ明示的に許可する必要があります。
:::

## ログ設定

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-log-max-lines` | `5000` | セッションのログバッファに残す最大行数。`nil` なら制限なし |
| `ecc-debug` | `nil` | 非 nil なら、生のプロトコルメッセージに加えて内部の診断トレースもログに残す |

`ecc-show-log` は、現在のバッファに結び付いたセッションの生のプロトコルログを表示します。処理に失敗したイベントが黙って捨てられることはありません。ログに残り、トランスクリプトには `unknown` ノードとして表示されます。
