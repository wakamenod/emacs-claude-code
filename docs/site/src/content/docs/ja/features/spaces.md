---
title: Space と worktree
description: プロジェクトごとに 1 タブ、全プロジェクトとセッションを一覧するサイドバー、セッションを置ける git worktree。
sidebar:
  order: 5
---

**Space** とは、Emacs のタブを 1 つ持つプロジェクトのことです。タブとはフレームの名前付きウィンドウ配置のことで、フレーム上端の帯を[出すかどうかは `tab-bar-show` 次第](#タブバーを出すかどうかはあなたが決める)です。git worktree はそれ自体が 1 つの Space になり、元のリポジトリの下に表示されます。

[`ecc-use-spaces`](/emacs-claude-code/ja/reference/configuration/#ecc-use-spaces) は既定でオンです。オフにすると以前の配置に戻ります。トランスクリプトはサイドウィンドウに入り、タブもサイドバーも worktree コマンドもありません。

```elisp
(setq ecc-use-spaces nil)
```

## Space の仕組み

![すべての Space とセッションを並べたサイドバー、プロジェクトごとのタブ、ソースと 2 つのトランスクリプトが横に並んだ 1 つの Space](../../../../assets/spaces.png)

```
┌ *ecc-sidebar* ─────┬ タブバー: [ecc] [herdr] [feat-x] ───────────────────┐
│ Spaces             │ ┌ ソース ─────────┬ session-A ────┬ session-B ────┐ │
│ ⚠ [1] ecc        ▾ │ │                 │ (タブライン)  │ (タブライン)  │ │
│    main ↑2 ↓0      │ │                 │               │               │ │
│   └─ ▶ [2] feat-x  │ │                 │               │               │ │
│ · [3] herdr        │ └─────────────────┴───────────────┴───────────────┘ │
│    master          │                                                     │
│                    │   1 つの Space = 1 つのタブ = 1 つのウィンドウ配置  │
│                    │                                                     │
│ Sessions           │                                                     │
│ ⚠ ecc   waiting    │                                                     │
│ ▶ ecc-2 running    │                                                     │
│ · herdr    idle    │                                                     │
└────────────────────┴─────────────────────────────────────────────────────┘
```

トランスクリプトは横に並びます。最初はソースの右隣に開き、以降は一番右のウィンドウを分割していきます。上下に積まれることはありません。そこから先は普通のウィンドウで、分割・移動・拡大・クローズは自由です。タブは**ウィンドウ構成そのもの**なので、別の Space に移って戻ってくると配置がそのまま復元されます。トランスクリプト内のタブラインは従来どおりで、そのプロジェクトのセッションを切り替えます。

トランスクリプトが `ecc-space-session-min-width` より狭くなることはありません。横に空きがなくなると、最も長く操作していないセッションがウィンドウを譲り、ウィンドウのないまま実行を続けます。そのセッションはサイドバーまたは `C-c c V` で戻せます。

**何も動いていない Space に移動すると、そこでセッションが起動します。** これが [`ecc-space-always-session`](/emacs-claude-code/ja/reference/configuration/#ecc-space-always-session)（既定でオン）で、最後のセッションを kill すると Space 自体が閉じるのも同じ設定です。以前の会話を続けるには、開いたセッションで `/resume` と入力します。オフにすると、Space はソースだけで開き、そのプロジェクトの最後のバッファを kill するまで残ります。

| キー | コマンド | 動作 |
|---|---|---|
| `C-c c j` | `ecc-space-goto` | Space を名前で選んで移動。記録しか残っていないプロジェクトも対象 |
| `C-c c z` | `ecc-space-zoom` | このウィンドウでタブ全体を埋める。同じキーで元の配置に戻る |
| `C-c c V` | `ecc-space-reset-windows` | この Space を新しいタブの初期配置（左にソース、その隣に transcript）に戻す |
| `C-c c ?` → `X` | `ecc-space-close` | この Space を閉じ、内部で実行中のプロセスをすべて停止する（リポジトリなら配下の worktree も含む）。閉じた worktree を削除するか確認する |
| — | `ecc-space-jump` | サイドバーの番号で N 番目の Space に移動 |

### タブバーを出すかどうかはあなたが決める

`tab-bar-mode` はタブの上に帯を描くだけで、ecc がこのモードを on にすることはありません。`tab-bar-show` が既定の `t` なら `tab-bar-new-tab` が on にし、`nil` に設定されていれば off のままにします。

```elisp
(setq tab-bar-show nil)   ; フレーム上端に帯を出さずに Space を使う
```

帯を隠しても、タブの作成・命名・切り替え・クローズはこれまでどおりで、一覧はサイドバーが受け持ちます。

## サイドバー

`C-c c b`（`ecc-sidebar-focus`）でサイドバーを開いてカーソルを移します。同じキーを押すと元のウィンドウに戻ります。ウィンドウには `no-other-window` が設定されているため、作業中に `C-x o` で入ることはありません。`ecc-use-spaces` がオフでも使え、その場合 `RET` と `1`–`9` はタブを作らずにそのプロジェクトへフォーカスします。

```
Spaces
⚠ [1] ecc                 ▾
   main ↑2 ↓0
  └─ ▶ [2] feat-x
· [3] herdr
   master

Sessions
⚠ ecc            waiting ×2
▶ ecc-2              running
· herdr                 idle
```

上半分は Space の一覧です。各行には、その Space の状態を示す印、`1`-`9` で使う番号、Space 名が並びます。リポジトリの下にはブランチと upstream との差が表示され、その worktree がツリー線でぶら下がり、それぞれブランチ名で表示されます。`TAB` で畳めます。

下半分はセッションの一覧で、印・名前・待っているものが並びます。印・色・点滅はタブラインと共通のため、セッションはどこに表示されても同じ状態を示します。

| キー | 動作 |
|---|---|
| `RET` | その行の Space またはセッションへ移動 |
| `n`, `p` | 次の行、前の行 |
| `TAB` | リポジトリの worktree を畳む／開く |
| `1`–`9` | その番号の Space へ移動 |
| `c` | この Space でセッションを開始 |
| `W` | この Space の worktree を作ってセッションを開始 |
| `k` | このセッションを停止 |
| `K` | この worktree のディレクトリを削除 |
| `X` | この Space を閉じる |
| `a`, `d` | このセッションが待っているものを許可／拒否（確認あり。`Bash` は対象外） |
| `g` | git の状態を更新して再描画 |
| `q` | サイドバーを隠す |

`a` と `d` の動作はダッシュボードと同じです（[セッション管理](/emacs-claude-code/ja/features/sessions/) を参照）。`ecc-sidebar-width` はサイドバーの幅（既定は 28 桁）、`ecc-sidebar-sessions-sort` は下半分の並び順で、`spaces`（既定）はセッションを Space ごとにまとめ、`priority` は答えを待っているものを先頭に出します。

## worktree

git の worktree は、独自ブランチを持つリポジトリの 2 つ目の作業ツリーです。2 つのセッションが互いの編集を見ずに同じプロジェクトで作業できます。以下のコマンドは `ecc-use-spaces` のオン・オフを問わず使えます。

| キー | コマンド | 動作 |
|---|---|---|
| `C-c c ?` → `W c` | `ecc-start-worktree` | リポジトリの隣にブランチをチェックアウトし、そこでセッションを開始 |
| `C-c c ?` → `W o` | `ecc-start-in-worktree` | 既存の worktree でセッションを開始 |
| `C-c c ?` → `W k` | `ecc-remove-worktree` | worktree で動いているセッションを停止し、worktree を削除 |

`ecc-start-worktree` はブランチの入力を求め、既存のブランチを候補に出します。既存のブランチはそのままチェックアウトされ、存在しないブランチは `HEAD` から作成されます。すでにどこかにチェックアウト済みのブランチは、拒否されるのではなく確認のうえその worktree に切り替わります。ecc が探すのはディレクトリ名ではなくブランチです。

worktree は `ecc-worktree-directory`（既定値は `.claude/worktrees`）に配置されます。相対パスはリポジトリ基準で、`feat/x` の worktree は `<repo>/.claude/worktrees/feat-x` に置かれます。絶対パスは全リポジトリで共有され、worktree は `<directory>/<repository>/<branch-slug>` に置かれます。

worktree で動く**最後の**セッションが終了すると、終了の仕方を問わず、ecc はその worktree を削除するか確認します。**ブランチが削除されることはありません。** `ecc-remove-worktree` が削除するのはディレクトリだけなので、コミット済みの変更が失われることはありません。git が clean と見なさない worktree（未コミットの変更や未追跡ファイルがある場合）は、もう一度確認が入ります。

## 作業を worktree のセッションに引き渡す

セッションの中で「worktree を切って X をやって」と頼むと、CLI は単体では `git worktree add` を実行し、同じ会話のまま作業を続けます。1 つのセッションが 2 つの worktree で作業することになります。

[Emacs の MCP サーバー](/emacs-claude-code/ja/start/installation/)を有効にしていると（`ecc-mcp-enabled`）、代わりに `start_worktree_session` ツールがモデルに提示されます。モデルがブランチ名を指定して依頼文を書くと、Emacs が worktree を作成して Space として開き、そこでセッションを起動して依頼文を送ります。依頼文には、Emacs が会話から追跡した内容（変更したファイル、作成した plan、記録ファイルのパス、未コミットの変更）が添えられます。worktree は `HEAD` から作られるため、未コミットの作業は先にコミットするか、依頼文に明記してください。

**他の 2 つの方法は阻止されます。** セッションがツールを持っている場合、`EnterWorktree` と Bash の `git worktree add` はツール名を挙げた 1 文で拒否されます。`auto` の許可モードでは CLI が Emacs に問い合わせないため（CLI 2.1.272 で実測）、下書きに *worktree*／*ワークツリー* が含まれていれば、ツールの存在を促す 1 行を添えて送信します。その 1 行はユーザーが書いたものではないので、プロンプトの下に折りたたまれた見出し（"1 line Emacs added"）として表示されます。

別の worktree がすでに保持しているブランチは拒否され、モデルには別のブランチ名を指定するよう伝えられます。Lisp からは `ecc-worktree-delegate` です。

worktree で開始したセッションは、元のリポジトリの下に自身の Space を開きます。
