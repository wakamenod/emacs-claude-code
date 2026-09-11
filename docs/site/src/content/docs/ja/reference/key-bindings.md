---
title: キーバインドリファレンス
description: ecc が割り当てるキーの全件。任意のバッファから、セッション内で、そしてセッションが開くバッファで。
sidebar:
  order: 3
---

セッション内ならどこからでも `C-c ?` でメニューが開きます。また、以下のどのバッ
ファでも `C-h m` を押せば、Emacs から見えるバインドの一覧が出ます。

## 任意のバッファから

`ecc-global-map` はプレフィックスキーマップです。好きなところに束縛してくださ
い。README では `C-c c` を勧めています。

```elisp
(use-package ecc
  :bind-keymap ("C-c c" . ecc-global-map))
```

`use-package` を使わない場合は次のようにします。

```elisp
(global-set-key (kbd "C-c c") ecc-global-map)
```

これらは何を編集している最中でも効きます。そこが肝心なところで、権限待ちで止
まったセッションを、わざわざ探しに行かなくて済みます。

| キー | コマンド | 動作 |
|---|---|---|
| `a` | `ecc-answer-allow` | 最も古い待機中リクエストを許可する |
| `d` | `ecc-answer-deny` | 最も古い待機中リクエストを、理由を尋ねたうえで拒否する |
| `1`–`4` | `ecc-answer-option-N` | 最も古い質問に選択肢 N で答える |
| `n` | `ecc-next-attention` | 次の待機中リクエストへ移動する。セッションをまたぎ、到着順で、末尾で先頭に戻る |
| `N` | `ecc-next-attention-in-project` | 同じだが、現在のプロジェクトのセッションに限る |
| `b` | `ecc-dashboard` | この Emacs が動かしているセッションの一覧 |
| `D` | `ecc-review` | セッション中の変更すべてを 1 つの diff として開く |
| `h` | `ecc-history-open` | 記録された会話を開く |
| `?` | `ecc-menu` | メニューを開く |

ここにある各キーは、メニューでも同じ意味を持ちます。1 つの文字が、どこで押され
ても 1 つの意味を運ぶということです。例外は `?` で、これはそのメニューを開くキー
であり、セッションでないバッファからメニューへ届く唯一の経路です。

## セッションバッファ内

セッションバッファは 2 つの領域からなります。上部の読み取り専用トランスクリプ
トと、下部の編集可能なプロンプトで、区切り線で隔てられています。**この 2 つは
キーマップが違います。**`ecc-chat-mode-map` がモードマップで、プロンプトが従う
のはこちらです。トランスクリプトはテキストプロパティとして
`ecc-chat-transcript-map` を持ち、そのマップが定義していないキーはモードマップ
へ落ちていきます。

### プロンプト

ここにあるのは `RET`、`TAB`、あるいはモードプレフィックス配下のキーだけです。文
字キーが文字のままでいられるようにするためです。例外は `/` ひとつで、これは自分
自身を挿入したうえでスラッシュコマンドを提示します。

| キー | コマンド | 動作 |
|---|---|---|
| `RET` | `ecc-chat-return` | 改行を挿入する。`ecc-chat-return-sends` が `t` なら送信する |
| `S-RET`, `C-j` | `ecc-chat-newline` | 改行を挿入する |
| `C-c C-c` | `ecc-prompt-send` | プロンプトを送信する |
| `C-c C-k` | `ecc-prompt-clear` | プロンプトを消す |
| `TAB` | `ecc-chat-tab` | 補完 |
| `/` | `ecc-chat-slash` | `/` を挿入してスラッシュコマンドを提示する |
| `C-k` | `ecc-chat-kill-line` | トランスクリプト側へ食い込まずに行を kill する |
| `S-TAB` | `ecc-chat-cycle-permission-mode` | 権限モードを順に切り替える |
| `C-c C-g` | `ecc-session-interrupt` | 実行中のターンを中断する |
| `C-c C-q` | `ecc-prompt-show-queue` | 送信待ちのものを表示する |
| `C-c C-r` | `ecc-prompt-resend-last` | 直前のプロンプトをもう一度送る |
| `C-c C-x` | `ecc-prompt-toggle-context` | エディタの文脈を添える／外す |
| `C-c C-i` | `ecc-prompt-insert-image` | 画像を挿入する |
| `C-c C-s` | `ecc-hint-accept-suggestion` | CLI が出した提案を受け入れる |
| `M-p`, `C-<up>` | `ecc-prompt-history-previous` | 履歴の前のプロンプト |
| `M-n`, `C-<down>` | `ecc-prompt-history-next` | 履歴の次のプロンプト |
| `C-c C-n` | `ecc-chat-next-turn` | 次のターン |
| `C-c C-p` | `ecc-chat-previous-turn` | 前のターン |
| `C-c C-a` | `ecc-perm-allow` | ツールの権限を許可する |
| `C-c C-d` | `ecc-perm-deny` | ツールの権限を拒否する |
| `C-c C-b` | `ecc-btw-show` | 脇質問を表示する |
| `C-c C-t` | `ecc-switch-session` | このウィンドウに別のセッションを表示する |
| `C-c C-e` | `ecc-session-export-markdown` | 会話を Markdown として書き出す |
| `C-c ?` | `ecc-menu` | メニューを開く |

:::note[ここに `C-c <文字>` が無い理由]
プレフィックス配下のキーはすべて `C-c C-<文字>` です。Emacs Lisp マニュアルは
`C-c <文字>` を利用者のために予約しており、しかもそれが利用者に予約された唯一の
領域だと述べています。モードがそこを取ると、利用者が使える唯一のキーを塞いでし
まうわけです。空いている `C-c C-<文字>` が無いコマンドは、キーを取らずにメニュー
へ回ります。待機中の全許可、ダッシュボード、diff レビューが専用キーを持たず
`C-c ?` や global マップ経由なのはそのためです。
:::

### トランスクリプト

打ち込む場所ではないので、こちらは単独の文字キーです。

| キー | コマンド | 動作 |
|---|---|---|
| `TAB` | `ecc-chat-toggle` | ポイント位置のノードを畳む／開く |
| `S-TAB` | `ecc-chat-cycle-permission-mode` | 権限モードを順に切り替える |
| `RET` | `ecc-session-visit` | ポイント位置のものを開く。ファイル、結果の全文、diff の全文 |
| `n` / `p` | `ecc-chat-next-heading` / `ecc-chat-previous-heading` | 次の／前の見出し |
| `M-n` / `M-p` | `ecc-chat-next-sibling` / `ecc-chat-previous-sibling` | 同じ深さの次の／前の兄弟 |
| `^` | `ecc-chat-up-heading` | 親の見出しへ |
| `]` / `[` | `ecc-chat-next-block` / `ecc-chat-previous-block` | 次の／前のブロック |
| `1`–`4` | `ecc-chat-show-level-N` | 深さ N までツリーを表示する |
| `+` / `-` | `ecc-chat-expand-all` / `ecc-chat-collapse-all` | すべて開く／すべて畳む |
| `SPC` / `DEL` | `scroll-up-command` / `scroll-down-command` | スクロール |
| `i` | `ecc-chat-goto-prompt` | プロンプトへ移動する |
| `a` | `ecc-perm-allow` | 待機中のリクエストを許可する |
| `d` | `ecc-session-review-or-deny` | 変更をレビューする、または拒否する |
| `f` | `ecc-chat-goto-files` | Files セクションへ移動する |
| `P` | `ecc-chat-goto-plans` | Plan セクションへ移動する |
| `T` | `ecc-session-timeline` | ターンを選ぶ |
| `w` | `ecc-session-copy-at-point` | ポイント位置のものをコピーする |
| `g` | `ecc-session-refresh` | 描き直す |
| `L` | `ecc-session-show-log` | 生のプロトコルログを表示する |
| `t` | `ecc-tui-open` | セッションをターミナルへ引き渡す |
| `R` | `ecc-session-resume` | セッションを再開する |
| `C-c C-k` | `ecc-session-interrupt` | 実行中のターンを中断する |
| `q` | `quit-window` | バッファを隠す |
| `?` | `ecc-menu` | メニューを開く |

### 回答待ちのノード上

回答待ちのノードは独自のキーマップを持ち、上のトランスクリプトマップを継承しま
す。これらのキーが効くのは、ポイントがそのノードの中にあるときだけです。

ノードは、トランスクリプトが空けているキーを足すことはあっても、既にあるキーに
別の意味を与えることはしません。これらのマップを選ぶのはポイントの位置であり、
位置は目で誤りやすいためです。1 行前と意味が違えば、警告もなく別のコマンドが走
ります。例外は `d` ひとつで、これは両者が一致するからです。
`ecc-session-review-or-deny` は、ポイントがリクエスト上にあれば `ecc-perm-deny`
へ回します。

| キー | コマンド | 動作 |
|---|---|---|
| `RET` | `ecc-session-visit` | 提案されているものを開く |
| `a` | `ecc-perm-allow` | 今回だけ許可する |
| `d` | `ecc-perm-deny` | 拒否する |
| `A` | `ecc-perm-allow-always` | 許可し、以後同種のものもすべて許可する |
| `u` | `ecc-perm-approve-turn` | ターンが終わるまで（until）すべて許可する |
| `r` | `ecc-perm-add-pattern` | ルール（rule）で許可する。与えたパターンをプロジェクト設定に保存する |
| `c` | `ecc-review-comment-request` | 提案内容にコメントする |
| `e` | `ecc-review-edit-proposal` | 許可する前に提案を編集する |

### Files セクションのファイル上

| キー | コマンド | 動作 |
|---|---|---|
| `RET` | `ecc-session-visit` | ファイルを開く |
| `d` | `ecc-session-review-file` | このファイルの変更をレビューする |

畳む／開くはトランスクリプトの他の場所と同じく `TAB`、`SPC` はスクロールです。

## セッションが開くバッファ

### diff レビュー（`ecc-review-mode`）

セッション中の変更すべてを 1 つの `diff-mode` バッファにしたものです。コメント
は hunk ごとに集められ、1 つのプロンプトとして送られます。

| キー | コマンド | 動作 |
|---|---|---|
| `c`, `C-c e` | `ecc-review-comment` | ポイント位置の hunk にコメントする |
| `C-c l` | `ecc-review-list-comments` | ここまでのコメントを一覧する |
| `C-c d` | `ecc-review-remove-comment` | ポイント位置のコメントを削除する |
| `e` | `ecc-review-edit-proposal` | 提案を編集する |
| `C-c C-c` | `ecc-review-send` | すべてのコメントを 1 つのプロンプトとして送る |
| `C-c C-k` | `ecc-review-quit` | 送らずに終える |
| `g` | `ecc-review-refresh` | 変更を読み直す |
| `q` | `quit-window` | バッファを隠す |

送信前にプロンプトが確認のため表示されます。`C-c C-c` で送信、`C-c C-k` で取り
消しです。編集した提案を適用する／取り消すのも同じ 2 つのキーです。

### プランレビュー（`ecc-plan-mode`）

ExitPlanMode リクエストが運んできたプランを、書き換え可能なバッファで開きます。

| キー | コマンド | 動作 |
|---|---|---|
| `C-c C-c` | `ecc-plan-approve` | プランを承認する |
| `C-c C-k` | `ecc-plan-deny` | 拒否する |
| `C-c c` | `ecc-plan-comment` | ポイント位置の行にコメントする |
| `C-c x` | `ecc-plan-remove-comment` | そのコメントを削除する |
| `C-c C-d` | `ecc-plan-show-diff` | プランに加えた変更を表示する |
| `C-c m` | `ecc-plan-set-mode` | 承認後に移る権限モードを選ぶ |
| `C-c C-n` | `ecc-plan-next-change` | 次の変更 |

フィードバックは 3 通りの道でモデルに届きます。行へのコメント、プラン本文そのも
のへの編集、そして理由を添えた率直な拒否です。

### 質問に答える（`ecc-question-mode`）

AskUserQuestion に答えるためのバッファです。

| キー | コマンド | 動作 |
|---|---|---|
| `1`, `2`, … | `ecc-question-choose` | その番号の選択肢を選ぶ |
| `SPC`, `RET` | `ecc-question-toggle-at-point` | ポイント位置の選択肢を切り替える |
| `o` | `ecc-question-other` | 自分で答えを書く |
| `n`, `TAB` / `p`, `S-TAB` | `ecc-question-next` / `ecc-question-previous` | 次の／前の選択肢 |
| `u` | `ecc-question-clear` | 選択を解除する |
| `C-c C-c` | `ecc-question-submit` | 送信する |
| `C-c C-k` | `ecc-question-cancel` | 取り消す |

### ダッシュボード（`ecc-dashboard-mode`）

| キー | コマンド | 動作 |
|---|---|---|
| `RET` | `ecc-dashboard-visit` | そのセッションへ移動する |
| `+` | `ecc-dashboard-new` | セッションを開始する |
| `k` | `ecc-dashboard-stop` | 停止する |
| `D` | `ecc-dashboard-delete` | 削除する |
| `r` | `ecc-dashboard-rename` | 名前を変える |
| `R` | `ecc-dashboard-resume` | 再開する |
| `a` / `d` | `ecc-dashboard-allow` / `ecc-dashboard-deny` | 待機中のリクエストを許可する／拒否する |
| `C` | `ecc-capabilities-show` | そのセッションにできること |
| `U` | `ecc-usage` | 使用量 |
| `g` | `ecc-dashboard-refresh` | 更新する |

### ケイパビリティ（`ecc-capabilities-mode`）

セッションが持つスキル、エージェント、コマンド、MCP サーバー、プラグインの一覧
です。

| キー | コマンド | 動作 |
|---|---|---|
| `RET` | `ecc-capabilities-visit` | ポイント位置のものを開く |
| `TAB` | `ecc-capabilities-toggle` | 畳む／開く |
| `g` | `ecc-capabilities-refresh` | 更新する |

### 使用量（`ecc-usage-mode`）

| キー | コマンド | 動作 |
|---|---|---|
| `g` | `ecc-usage-refresh` | もう一度問い合わせる |
| `b` | `ecc-usage-toggle-behaviors` | 各上限に達したとき何が起きるかを表示する／隠す |
| `q` | `ecc-usage-hide` | 片付ける |

### 脇質問（`ecc-btw-mode`）

| キー | コマンド | 動作 |
|---|---|---|
| `a` | `ecc-btw-ask-again` | 別のことを尋ねる |
| `c` | `ecc-btw-copy` | 回答をコピーする |
| `k` | `ecc-btw-cancel` | 送信中の質問を取り消す |
| `x` | `ecc-btw-clear` | 表示を消す |
| `g` | `ecc-btw-refresh` | 更新する |
| `q` | `ecc-btw-hide` | 隠す |

## 自分のソースバッファ内

この 2 つはセッションバッファのものではありません。コードそのものから手を伸ばす
ためのものです。それぞれ対象の領域にキーマップをかぶせ、回答を受け入れるか片付
けるまでの間だけ有効になります。

### インラインの回答（`ecc-inline-prompt`）

| キー | コマンド | 動作 |
|---|---|---|
| `n` / `p` | `ecc-inline-scroll-down` / `ecc-inline-scroll-up` | 回答をスクロールする |
| `r` | `ecc-inline-prompt` | 別のことを尋ねる |
| `q` | `ecc-inline-quit` | 片付ける |

### 受け入れ待ちの書き換え（`ecc-rewrite`）

受け入れるまで、バッファには何も書き込まれません。

| キー | コマンド | 動作 |
|---|---|---|
| `RET`, `y` | `ecc-rewrite-accept` | 書き換えを受け入れる |
| `d` | `ecc-rewrite-diff` | まず diff として見る |
| `m` | `ecc-rewrite-merge` | 手作業でマージする |
| `n` / `p` | `ecc-inline-scroll-down` / `ecc-inline-scroll-up` | スクロール |
| `q` | `ecc-rewrite-cancel` | 何も変えずに取り消す |
