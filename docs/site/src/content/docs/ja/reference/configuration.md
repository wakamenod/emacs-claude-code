---
title: 設定
description: ecc のすべての customize 設定を分野ごとにまとめます。
sidebar:
  order: 3
---

このページには、ecc のすべての `defcustom` を載せています。どれも `ecc` グループにあります。

```
M-x customize-group RET ecc
```

機能のページには、customize に出ない変数もいくつか出てきます。それらは `setq` で設定します。

## CLI とセッション

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-executable` | `"claude"` | Claude Code の CLI。`PATH` 上の名前かパス |
| `ecc-permission-mode` | `nil` | セッションを始めるときのモード（`--permission-mode`）: `"default"`、`"acceptEdits"`、`"plan"`、`"auto"`、`"bypassPermissions"`。`nil` なら CLI のデフォルトのまま |
| `ecc-plan-default-mode` | `"acceptEdits"` | モードを選ばずにプランを承認したときに切り替えるモード。`nil` なら変更を求めず、CLI はデフォルトのモードに戻る |
| `ecc-prompt-suggestions-enabled` | `nil` | 非 nil なら `--prompt-suggestions` を渡し、CLI が次のプロンプトを提案する |
| `ecc-command-wrapper-function` | `nil` | `(command-list project-root)` を受け取り、代わりに実行するコマンドを返す関数 |
| `ecc-disabled-plugins` | `nil` | ecc が始めるセッションで無効にするプラグイン（`"name@marketplace"`）。ターミナルのクライアントでは有効のまま |

モデルや予算の設定はありません。どちらも Claude Code の設定で決めます。再開したセッションは、最後のターンのモデルを使います。実行中のセッションのモデルを変えるには、メニューの `m` か `/model` を使います。

## トランスクリプト

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-chat-return-sends` | `nil` | `t` なら、ターミナルのクライアントと同じく `RET` で送信。`C-c C-c` はいつでも送信 |
| `ecc-chat-text-width` | `100` | テキストの幅（桁数）。`nil` ならウィンドウの幅いっぱい |
| `ecc-chat-line-spacing` | `0.15` | 各行の下に足す間隔。`line-spacing` と同じ。`nil` なら足さない |
| `ecc-render-result-max-lines` | `12` | ツールの結果を表示する行数。`RET` で全体を表示 |
| `ecc-render-inhibit-inline-diff` | `nil` | `t` なら、ファイルを変える呼び出しを畳んで表示。`TAB` で開く |
| `ecc-render-diff-max-lines` | `40` | ツールの呼び出しやリクエストで diff を表示する行数。`RET` で全体を表示 |
| `ecc-diff-context-lines` | `3` | トランスクリプトで変更の前後に出す文脈の行数 |
| `ecc-stream-throttle` | `0.05` | ストリーミングされたテキストを描画する前にためる秒数。`0` なら届くたびに描画 |
| `ecc-render-debounce` | `0.1` | トランスクリプトの変化している部分を再描画するまでの待ち時間（秒） |
| `ecc-show-hook-events` | `nil` | 非 nil なら、フックが動くたびに終了コードと出力とともに表示する。フックはどちらの場合も動く。セッションを始めるときに読む |
| `ecc-image-inline` | `t` | `nil` なら、画像や動画はファイル名の行だけを表示 |

## ヘッダー行とモードライン

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-hint-context-indicator` | `t` | ヘッダー行にコンテキストウィンドウの残りを表示 |
| `ecc-prompt-suggestion-display` | `t` | 空のプロンプト領域に CLI の提案を表示（`ecc-prompt-suggestions-enabled` が必要） |
| `ecc-mode-line-format` | `nil` | モードラインにセッションを表示する書式。`nil` なら表示しない |

`ecc-mode-line-format` では次の指定子を使えます。

| 指定子 | 意味 |
|---|---|
| `%n` | セッション名 |
| `%m` | モデル |
| `%p` | 権限モード |
| `%l` | コンテキストウィンドウの残り（パーセント） |
| `%t` | コンテキストウィンドウのトークン数 |
| `%c` | ここまでのコスト |
| `%r` | レート制限の使用率 |
| `%s` | セッションの状態 |

## 通知

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-notify-level` | `'message` | `'message` はエコーエリア、`'pulse` はさらにトランスクリプトを光らせる、`'desktop` はデスクトップ通知、`nil` は通知しない |
| `ecc-notify-events` | `'(turn-finished request exited)` | 通知するもの: ターンの終了、リクエスト、プロセスの終了 |
| `ecc-notify-suppress-when-focused` | `t` | Emacs にフォーカスがある間はデスクトップ通知を出さない |
| `ecc-notify-sound` | `nil` | デスクトップ通知で鳴らすシステムのサウンド（macOS なら `"Glass"` など） |
| `ecc-notify-function` | `#'ecc-notify-default` | 通知の代わりに呼ぶ `(SESSION EVENT TEXT)` の関数 |

## レビュー

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-review-style` | `'diff` | `'diff` はレビューを 1 つの `diff-mode` バッファで、`'ediff` は [ediff で](/emacs-claude-code/ja/features/review-ediff/)開く |
| `ecc-review-menu-count-session-changes` | `t` | レビューのメニューの `D` の横に、セッションが変えたファイルの数を表示。メニューが開くのが遅くなるなら `nil` |
| `ecc-review-auto-refresh` | `t` | セッションのツールやターンが終わったとき、ファイルを保存したときに、開いているレビューを読み直す。`nil` なら `g` でだけ読み直す |
| `ecc-review-files-width` | `32` | レビューの横のファイルの一覧の幅 |
| `ecc-review-ediff-layout` | `'stacked` | ediff のレビューを開くときの並び: `'stacked` か `'side-by-side` |
| `ecc-review-talk-reply-width` | `75` | 上下に並べた ediff のレビューの右に置く返答の欄の幅 |
| `ecc-review-talk-reply-height` | `12` | 左右に並べた ediff のレビューの下に置く返答の欄の高さ。`nil` なら欄を出さない |
| `ecc-review-talk-reply-place` | `'auto` | `'frame` なら返答の欄を専用のフレームに出す |

## ウィンドウ

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-use-spaces` | `t` | プロジェクトごとにタブを作る。`nil` なら[以前のレイアウト](/emacs-claude-code/ja/features/spaces/#space-を使わないとき) |
| `ecc-space-always-session` | `t` | 何も動いていない Space を開くとセッションを始め、最後のセッションを閉じると Space も閉じる |
| `ecc-space-session-min-width` | `80` | トランスクリプトを狭める限度。これより狭くなるなら、新しいセッションは既存のウィンドウを使う |
| `ecc-sidebar-width` | `28` | サイドバーの幅 |
| `ecc-window-large-frame-min-height` | `80` | Space がオフのとき: 3 つ目のセッションウィンドウに必要なフレームの高さ（行数） |
| `ecc-window-sub-height` | `0.33` | Space がオフのとき: 3 つ目のセッションウィンドウの高さ |

## 補助バッファとポップアップ

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-btw-display` | `'window` | `/btw` の答えを出す場所 |
| `ecc-usage-display` | `'window` | 使用量のレポートを出す場所 |

どちらも `'window` か、フレームの上に浮かぶポップアップの `'posframe` を取ります。`'posframe` には [posframe](https://github.com/tumashu/posframe) パッケージとグラフィカルなフレームが必要で、なければウィンドウを使います。

## MCP サーバー

ecc はループバックインターフェイスで MCP サーバーを動かし、各セッションに登録できます。Claude は Emacs の `xref`、`imenu`、tree-sitter、プロジェクト、診断を読み、[レビューで作業し](/emacs-claude-code/ja/features/review-claude/)、[worktree に作業を引き渡せる](/emacs-claude-code/ja/features/spaces/#作業を-worktree-のセッションに引き渡す)ようになります。

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-mcp-enabled` | `nil` | すべてのセッションにサーバーを登録する。最初に使うときに起動し、`M-x ecc-mcp-stop` で止める |
| `ecc-mcp-enable-execute-code` | `nil` | Claude に任意の Elisp を評価させるツールを提供する |
| `ecc-mcp-excluded-tools` | `nil` | 登録しないツールの名前。遅いツールなど |
| `ecc-worktree-auto-allow-removal` | `t` | `remove_worktree` が[終わった worktree を削除する](/emacs-claude-code/ja/features/spaces/#終わった-worktree-を削除する)ときに確認しない |

:::caution[2 つの別々の有効化]
`ecc-mcp-enabled` は `ecc-mcp-enable-execute-code` を有効にしません。そのツールで動くコードは、Emacs でユーザーと同じ権限を持ちます。
:::

## ログ

| 変数 | 既定値 | 説明 |
|---|---|---|
| `ecc-log-max-lines` | `5000` | セッションのログバッファに残す行数。`nil` ならすべて残す |
| `ecc-debug` | `nil` | ecc 内部のトレースもログに出す |

`M-x ecc-show-log`（メニューの `L`）で、セッションのプロトコルのログを表示します。ecc が処理できなかったメッセージはログに残り、トランスクリプトに `unknown` ノードとして表示されます。
