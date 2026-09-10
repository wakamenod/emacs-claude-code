[English](README.md) | **日本語**

---

# ecc

Claude Code CLI の Emacs クライアント。会話は普通の Emacs バッファに置かれる。

![Emacs 29.1+](https://img.shields.io/badge/Emacs-29.1%2B-7F5AB6)
![Claude Code CLI](https://img.shields.io/badge/Claude%20Code-CLI-D97757)

![セッションバッファ。上が transcript、下がプロンプト](docs/images/session.png)

**ドキュメント:** <https://wakamenod.github.io/emacs-claude-code/> *(準備中)*

## ecc とは

ecc は `claude` を headless で起動し、その stream-json プロトコルをパイプで読み、会話を
ひとつの Emacs バッファに描く。上が読み取り専用の transcript、下が編集できるプロンプト
領域、その間に区切り線がある。中身はただのバッファのテキストなので、検索も `occur` も
narrow も yank も Markdown への書き出しも効く。face は挿入時に付けているので `customize`
から届く。

その代わりに諦めたものがあり、それははっきり書いておくほうがいい。ecc は CLI の
ターミナル UI を再現しない。本物が要るときは `ecc-tui-open` が動いているセッションを
そちらへ渡し、終わったら戻してもらう。話すのは Claude Code のプロトコルなので、ecc は
Claude Code のクライアントであってそれ以外ではない。Markdown もテーブルも diff も、
ecc なりの読み方であって完全な実装ではない。必要なのは Emacs 29.1 と `claude` CLI。
それだけである。

CLI 自身のプロトコルを話すということは、見えているものが CLI の言ったことそのもの
だということでもある。許可の確認は CLI が本当に出している要求で、使用量の数字は CLI の
`get_usage` から来ており、過去の会話は CLI の記録から読み戻している。ここに推測は無い。

セッションの周りの作業も一級市民として扱う。そのセッションが加えた変更をまとめて
ひとつの `diff-mode` バッファで読み、hunk にコメントを付け、まとめて一度のプロンプトで
送れる。適用される前の編集提案を読み、提案そのものを書き換えてから許可できる。プランは
書き込めるバッファの上で詰められる。答え待ちの要求には、そのときいるバッファがどこで
あっても答えられる。複数のセッションを同時に走らせ、ダッシュボードから見分けられる。
拒否がどこでも既定の答えで、Emacs の MCP サーバは自分で有効にするまで動かず、Elisp を
評価するツールにはさらに別の判断が要る。Emacs から出たくない人のための Claude Code
クライアントである。

## 必要なもの

- **Emacs 29.1 以降。** `transient` は Emacs 同梱なので、他に入れるものは無い。
- **[Claude Code CLI](https://docs.claude.com/en/docs/claude-code)** が `PATH` にあること。
  無ければ `ecc-executable` で場所を教える。

次の 4 つは、あれば使い、無ければ使わない:
[ghostel](https://github.com/dakra/ghostel) はターミナルへの引き渡しに、
[posframe](https://github.com/tumashu/posframe) は `/btw` と使用量のポップアップに、
[nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) はツールのアイコンに、
[markdown-mode](https://github.com/jrblevin/markdown-mode) はプランとレビューのバッファの
親モードに使う。無い場合は代替に落ちるだけで、失敗はしない。

## インストール

ecc は MELPA には無い。このリポジトリから入れる。

**Emacs 30 以降**、`use-package` と `:vc` で:

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest))
```

`:vc` キーワードは Emacs 30 からのもの。0.1.0 のうちはブランチを追うより、
`:rev "<sha>"` でコミットを固定するほうがいいかもしれない。

**Emacs 29** では `package-vc-install` を使う:

```
M-x package-vc-install RET https://github.com/wakamenod/emacs-claude-code RET
```

そのうえで `:vc` の無い普通の `use-package` フォームを書く。

<details>
<summary>straight.el、Elpaca、手動 clone</summary>

リポジトリ名は `emacs-claude-code`、パッケージ名は `ecc` で違うので、レシピの側で
`ecc` と明示する必要がある。リポジトリ名からは決まらない。

```elisp
;; straight.el
(use-package ecc
  :straight (ecc :type git :host github :repo "wakamenod/emacs-claude-code"))

;; Elpaca
(use-package ecc
  :ensure (ecc :host github :repo "wakamenod/emacs-claude-code"))
```

手で入れるなら:

```sh
git clone https://github.com/wakamenod/emacs-claude-code ~/.emacs.d/site-lisp/emacs-claude-code
```

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/emacs-claude-code")
(require 'ecc)
```

`(require 'ecc)` は全ファイルを読む。コマンドは autoload されているので `M-x ecc-start`
は `require` 無しでも動く。`ecc-global-map` はコマンドではなく変数なので、`use-package`
の外で束縛するには先に ecc が読み込まれている必要がある。`use-package` ではこれを
`:bind-keymap` が引き受ける。
</details>

## 設定

```elisp
(use-package ecc
  :ensure t
  :vc (:url "https://github.com/wakamenod/emacs-claude-code" :rev :newest)
  ;; `ecc-global-map' はどのバッファからでも答え待ちの要求に答えるためのもの。
  ;; 下のキー割り当てを参照。コマンドではなく変数に入ったキーマップなので
  ;; `:bind-keymap' を使う。これならプレフィックスを最初に押した時点で ecc が
  ;; 読み込まれ、起動時には読まれない。
  :bind-keymap ("C-c c" . ecc-global-map)
  :bind ("C-c C-v" . ecc-start)
  :config
  (setq ecc-chat-text-width 100)      ; transcript を描く桁数
  (setq ecc-notify-level 'pulse)      ; nil, `message', `pulse', `desktop'
  (setq ecc-permission-mode nil)      ; nil なら CLI 自身の既定のまま

  ;; RET は改行、送信は C-c C-c。ターミナルのクライアントのように RET で送りたい
  ;; ときは t にする。
  (setq ecc-chat-return-sends nil)

  ;; Emacs にしか分からないこと -- xref、imenu、tree-sitter、project、診断 -- を
  ;; Claude から訊けるようにする。セッションごとに登録される loopback の MCP
  ;; サーバ経由。既定では無効。
  ;; (setq ecc-mcp-enabled t)
  ;; 任意の Elisp を自分の Emacs で評価させるかどうかは、別の判断として扱う。
  ;; (setq ecc-mcp-enable-execute-code t)
  )
```

残りは `M-x customize-group RET ecc` にある (`defcustom` は全部で 30)。`defcustom` で
ないものもただの `defvar` なので `setq` で届く。
[設定リファレンス](https://wakamenod.github.io/emacs-claude-code/)を参照。

## 最初のセッション

1. `M-x ecc-start` で、いまのバッファのプロジェクトに対してセッションが始まる。
2. 区切り線より下、プロンプト領域に書く。
3. `C-c C-c` で送信。`RET` は改行。
4. Claude がツールを使う許可を求めてきたら、`C-c C-a` で許可、`C-c C-d` で拒否。
   **既定は拒否**。目を離している間に何かが動くことはない。
5. `C-c ?` でメニューが開く。残りはすべてそこにある。

## キー割り当て

上で `C-c c` に束縛した `ecc-global-map` は、どのバッファからでも効く:

| キー | コマンド | |
|---|---|---|
| `a` | `ecc-answer-allow` | いちばん古い要求を許可する |
| `d` | `ecc-answer-deny` | 拒否する |
| `1`–`4` | `ecc-answer-option-N` | 質問に選択肢 N で答える |
| `n` | `ecc-next-attention` | 待っているセッションへ行く |
| `N` | `ecc-next-attention-in-project` | 同じことを、このプロジェクトの中で |
| `D` | `ecc-dashboard` | セッションを一覧する |
| `h` | `ecc-history-open` | 過去の会話を開く |

セッションバッファの中では:

| キー | |
|---|---|
| `C-c C-c` | プロンプトを送る |
| `S-RET` | 改行 |
| `TAB` | プロンプトでは補完、transcript では折り畳みの開閉 |
| `C-c C-a` / `C-c C-d` | 許可 / 拒否 |
| `C-c ?` | メニュー |

残りの 40 ほどは
[キー割り当てリファレンス](https://wakamenod.github.io/emacs-claude-code/)にある。

## 謝辞

ecc は 4 つのプロジェクトを読むところから始まり、それぞれから何かを受け取っている。

- **[claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el)** — CLI との
  IDE 側の統合を最後までやるとどうなるかを見せてくれた。
- **[claude-code.el](https://github.com/stevemolitor/claude-code.el)** — セッションを
  Emacs の客ではなく一部のように感じさせる、細かな手当ての数々を。
- **[eca-emacs](https://github.com/editor-code-assistant/eca-emacs)** — 会話を本物の
  Emacs バッファとして描くこと、そしてインラインのオーバーレイ chat の形を。
- **[emacs-gravity](https://github.com/gdanov/emacs-gravity)** — 会話を辿れる構造として
  扱うこと、それにプランのレビューと許可パターンを。

作者の方々に感謝する。

## 比較

いずれも筋の通った 5 つの設計である。この表はどれが勝ったかではなく、それぞれが何を
選んだかの記録である。2026 年 9 月時点で私の知る限り正確だが、すでに古くなっている
かもしれない。あなたのプロジェクトの行が間違っていたら issue で教えてほしい。直す。

| プロジェクト | Claude との話し方 | 表示 | Emacs と CLI 以外に要るもの | Emacs | 入手 |
|---|---|---|---|---|---|
| [claude-code-ide.el](https://github.com/manzaltu/claude-code-ide.el) | ターミナルバッファの中の CLI の TUI と、Emacs 内の WebSocket MCP サーバ | ターミナルエミュレータ | `websocket`, `transient`, `web-server` | 28.1 | MELPA |
| [claude-code.el](https://github.com/stevemolitor/claude-code.el) | ターミナルバッファの中の CLI の TUI | ターミナルエミュレータ | `transient`, `inheritenv` | 30 | MELPA |
| [eca-emacs](https://github.com/editor-code-assistant/eca-emacs) | 別プロセスの `eca` サーバへの JSON-RPC | Markdown の chat バッファとインラインのオーバーレイ | `dash`, `s`, `f`, `markdown-mode`, `compat`, `eca` バイナリ | 28.1 | MELPA |
| [emacs-gravity](https://github.com/gdanov/emacs-gravity) | Claude Code のプラグインフック、Node の shim、socket サーバ | magit-section の turn ツリー | `magit-section`, `transient`, Node.js | 27.1 | GitHub |
| **ecc** | `claude` を headless で、stream-json をパイプで | ひとつの Emacs バッファ: transcript とプロンプト | 無し | 29.1 | GitHub, 0.1.0 |

それぞれが強いところ:

- **claude-code-ide.el** は成熟していて MELPA にあり、本物の TUI と IDE 側の MCP 統合が
  そろって手に入る。
- **claude-code.el** は Claude Code を Emacs に持ち込む最も軽い道で、ターミナルの再現度は
  完全である。それがターミナルそのものだから。
- **eca-emacs** は特定のベンダに縛られないので、モデルの提供元が変わっても生き残る。
- **emacs-gravity** はプラグインフックから動くので、この Emacs が起動していない
  セッションも見える。tmux やメニューバーアプリなど、Emacs の外にも届く。

## ライセンス

GPL-3.0-or-later。[LICENSE](LICENSE) を参照。
