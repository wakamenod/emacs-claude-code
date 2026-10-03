---
title: キーバインド
description: どのバッファからでも利用できるグローバルキーバインドと設定方法。
sidebar:
  order: 1
---

`ecc-global-map` は、ほかのファイルを編集している最中によく使うコマンドをまとめたプレフィクスキーマップです。セッションのバッファに移らなくても、権限の確認に答えたり、動いているセッションに切り替えたりできます。好きなプレフィクスに割り当ててください。[インストール](/emacs-claude-code/ja/start/installation/#最初の設定)のページでは `C-c c` を使っています:

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
| `c` / `r` / `R` | セッション開始 / 再開（`C-u r` で会話を分岐） / 名前変更 |
| `v` / `i` / `t` | プロンプト入力へ移動 / 実行中断 / ターミナルへ引き渡し |
| `a` / `d` | 最古の待機中リクエストを許可 / 拒否 |
| `1`–`4` | 待機中の質問に、対応する選択肢で回答 |
| `n` / `N` | 次の待機中リクエストへ移動（全体 / 現在のプロジェクト内） |
| `B` / `D` / `h` / `U` | ダッシュボードを開く / レビューする対象を選ぶ / 履歴閲覧 / 使用量確認 |
| `j` / `b` / `z` / `V` | Space へ移動 / サイドバーを開く / このウィンドウをズーム / この Space のウィンドウ配置を整え直す（[Space と worktree](/emacs-claude-code/ja/features/spaces/) を参照） |
| `/` | 過去の会話を発言内容から検索 |
| `?` | Transient メニューを開く |

キーは [Transient メニュー](/emacs-claude-code/ja/features/menu/)と同じです。`?` は Transient メニューそのものを開き、セッションバッファの外からすべての ecc コマンドを呼び出せます。

たまにしか使わないコマンドはここに載せていません。worktree の作成・オープン・削除は、`?` のあと `W` を押します。ウィンドウを別のセッションに切り替えるには、セッションバッファ内で `C-c C-t` を押します。`ecc-use-spaces` がオフのときに 1 つのプロジェクトへ絞り込むには `M-x ecc-focus-project` を実行します。

セッションバッファ内だけのキーバインドは、[プロンプトとトランスクリプト](/emacs-claude-code/ja/features/prompt/)を参照してください。
