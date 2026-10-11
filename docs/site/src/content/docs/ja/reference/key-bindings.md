---
title: キーバインド
description: 好きなプレフィクスに割り当てて、どのバッファからでも使うグローバルなキーマップ。
sidebar:
  order: 1
---

`ecc-global-map` には、ほかのファイルを編集しながら使うコマンドが入っています。リクエストに答える、セッションへ移る、レビューを開く、などです。好きなプレフィクスに割り当ててください。[インストール](/emacs-claude-code/ja/start/installation/#最初の設定)のページでは `C-c c` を使っています。

```elisp
(use-package ecc
  :bind-keymap ("C-c c" . ecc-global-map))
```

`use-package` を使わない場合:

```elisp
(global-set-key (kbd "C-c c") 'ecc-global-map)
```

| キー | 動作 |
|---|---|
| `c` / `r` / `R` | セッションを開始 / 再開（`C-u r` で分岐） / 名前を変更 |
| `v` / `i` / `t` | プロンプトへ移動 / ターンを中断 / ターミナルへ引き渡す |
| `a` / `d` | 最も古い応答待ちのリクエストを許可 / 拒否 |
| `1`〜`4` | 応答待ちの質問にその選択肢で答える |
| `n` / `N` | 次の応答待ちのリクエストへジャンプ（全体 / このプロジェクト） |
| `B` / `D` / `h` / `U` | ダッシュボード / レビューのメニュー / 記録を読む / 使用量 |
| `j` / `b` / `z` / `V` | [Space](/emacs-claude-code/ja/features/spaces/): 移動 / サイドバー / このウィンドウを広げる / この Space のウィンドウを並べ直す |
| `/` | 過去の会話を検索 |
| `?` | すべてのコマンドがある[メニュー](/emacs-claude-code/ja/reference/menu/)を開く |

キーの意味はメニューでも同じです。worktree のコマンドは `?` → `W` にあります。

セッションバッファの中のキーは[プロンプトとトランスクリプト](/emacs-claude-code/ja/features/prompt/)にあります。
