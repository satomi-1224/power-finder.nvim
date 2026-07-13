# Contributing

power-finder.nvim への貢献を歓迎します。

## 開発環境

- Neovim 0.10+
- ripgrep（`rg`）
- 任意: [stylua](https://github.com/JohnnyMorganz/StyLua)（整形）

## テスト

`plenary.nvim` を用いた headless テストです。`tests/deps/` に自動取得されます。

```sh
make test        # 全 spec を実行
```

設計方針として、検索エンジンの中核ロジック（`engine` / `parser` / `replace` / `util` /
`scope`）は Neovim UI に依存しない純粋関数として実装し、単体テストで網羅しています。
新しいロジックはできるだけこの純粋層に置き、`tests/spec/` にテストを追加してください。

> 補足: 本リポジトリの CI/ローカルでは `PlenaryBustedDirectory` の代わりに
> in-process ランナー `tests/run.lua` を使っています（headless で子ジョブが
> ハングする環境があるため）。新しい spec は `tests/spec/*_spec.lua` に置けば自動で拾われます。

## コードスタイル

- stylua（`stylua.toml`: 2 スペースインデント / 120 桁）に従ってください。

```sh
make fmt         # 整形
make lint        # 整形チェック（CI と同じ）
```

## プルリクエスト

1. `main` から作業ブランチを切る
2. 変更 + テスト追加
3. `make test` と `make lint` が通ることを確認
4. PR を作成（テンプレートに沿って記入）

CI（`test` ジョブ）が通ることがマージの条件です。
