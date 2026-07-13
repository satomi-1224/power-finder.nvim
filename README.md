# power-finder.nvim

[![CI](https://github.com/satomi-1224/power-finder.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/satomi-1224/power-finder.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white)

Zed / IntelliJ の *Find in Files* 級のプロジェクト検索・一括置換を Neovim ネイティブで。
構造化フォームで条件を組み、ライブで結果を見て、diff を確認してから安全に置換します。

- **一体型パネル** — 上部の条件フォーム（Search / Replace / Include / Exclude）と、
  下部の読み取り専用結果を、フローティング2ウィンドウで表示。
- **ライブ検索** — 入力のたびにデバウンス付きで ripgrep を再実行。進行中の検索はキャンセル。
- **正規表現 / case / word** — トグルで即切替（既定はすべて OFF＝リテラル・大小無視・部分一致）。
- **Include / Exclude glob** — 対象・除外を glob で指定（カンマ区切りで複数）。
- **検索スコープ** — Project（git ルート）/ Cwd / 開いているバッファ / 任意パス。
- **diff プレビュー置換** — ripgrep の `--replace` で `$1` 等のキャプチャ参照も正確に算出。
  ファイル単位でチェックし、mtime による競合検知付きで安全に一括適用。
- **quickfix 連携** — 結果を quickfix へ送って既存ワークフローへ橋渡し。
- **Selenized 準拠** — 標準ハイライトへリンクするので、そのままの配色に馴染む。

> 設計の背景と意思決定は [`DESIGN.md`](./DESIGN.md)、UI/UX の視覚プレビューは
> [`mockup.html`](./mockup.html) を参照（どちらも旧称 `search-ui` 時代の名残がありますが
> 内容は本プラグインの設計です）。

## 要件

- Neovim **0.10+**（開発・検証は 0.12.3）
- [ripgrep](https://github.com/BurntSushi/ripgrep)（`rg`）
  - 検索のみなら任意のバージョンで可
  - **一括置換のプレビューは ripgrep 15+** が必要（`rg --json` の `replacement`
    フィールドを利用するため。古い rg では置換時に明示的なエラーで通知します）
- 任意: [fzf-lua](https://github.com/ibhagwan/fzf-lua)（スコープの任意パス選択 picker に利用）
- 任意: [fd](https://github.com/sharkdp/fd)（パス picker が高速化。無ければ `find` を使用）

## インストール

### lazy.nvim

```lua
{
  "power-finder.nvim",           -- ローカル開発中は dir = "/path/to/power-finder.nvim"
  dependencies = { "ibhagwan/fzf-lua" }, -- 任意
  opts = {},                     -- setup() が呼ばれる
}
```

### nix home-manager（ローカルディレクトリ参照）

`programs.neovim.plugins` あるいは lazy スペックで、ローカルパスを参照します。

```nix
# lazy を使っている場合、開発中はローカル参照が手軽:
#   { dir = "/Users/you/ghq/github.com/you/power-finder.nvim", opts = {} }
```

リポジトリ化後は通常の GitHub 参照に切り替えてください。

## 使い方

```vim
:PowerFinder                 " パネルを開く
:PowerFinder handleRequest   " 検索語をあらかじめ入れて開く
:PowerFinderCword            " カーソル下の単語で開く
```

Lua:

```lua
require("power-finder").open()               -- 空の状態で開く
require("power-finder").open({ query = "x" })
require("power-finder").open_cword()
```

デフォルトのグローバルキーマップは `<leader>sf`（`opts.keymap` で変更 / `false` で無効）。

## パネル内キーマップ（既定）

| コンテキスト | キー | 動作 |
| --- | --- | --- |
| フォーム/結果 | `<C-r>` / `<C-c>` / `<C-w>` | regex / case / word トグル |
| フォーム/結果 | `<C-s>` | スコープ picker |
| フォーム/結果 | `<C-d>` | 置換プレビューへ |
| フォーム | `<C-j>` | 結果ウィンドウへ移動 |
| 結果 | `<C-k>` | フォームへ戻る |
| 結果 | `<CR>` | 該当箇所を開く（プレビュー中は適用） |
| 結果 | `<C-x>` / `<C-v>` | 分割 / 垂直分割で開く |
| 結果 | `<Tab>` | ファイル折りたたみ（プレビュー中は対象トグル） |
| 結果 | `<C-q>` | quickfix へ送る |
| プレビュー | `<Space>` | ファイルの適用対象トグル |
| プレビュー | `<CR>` | チェック済みを一括適用 |
| 全体 | `q` | 閉じる（プレビュー中は検索へ戻る） |

## 設定

`setup()` に渡せる主な項目（既定値は [`lua/power-finder/config.lua`](./lua/power-finder/config.lua)）:

```lua
require("power-finder").setup({
  keymap = "<leader>sf",
  layout = { width = 0.82, height = 0.86, border = "rounded" },
  search = {
    debounce_ms = 120,
    min_query = 1,
    max_results = 10000,
    max_columns = 4096,
    hidden = false,
    no_ignore = false,
  },
  defaults = {
    include = "",
    exclude = "",
    scope = "project",  -- "project" | "cwd" | "buffers" | "path"
    regex = false,      -- OFF => literal (fixed-strings)
    case = false,       -- OFF => ignore case, ON => case-sensitive
    word = false,
  },
  replace = { write_buffers = true },
  fzf = { use_for_scope_picker = true },
  rg = "rg",
  mappings = { --[[ 上表のキーを個別に変更可 ]] },
})
```

## アーキテクチャ

vim 非依存の純粋ロジックと、副作用を持つ層を分離しています。

| モジュール | 責務 | 純粋性 |
| --- | --- | --- |
| `engine` | 条件 → ripgrep 引数の組み立て | 純粋 |
| `parser` | `rg --json` イベント → 結果モデル | 純粋（`vim.json`のみ） |
| `replace` | 置換行の組み立て・diff・一括適用 | compute部は純粋 / apply はI/O |
| `util` / `scope` | 文字列・glob・スコープ解決 | ほぼ純粋 |
| `search` | `vim.system` による非同期実行・デバウンス・キャンセル | I/O |
| `panel` / `form` / `config` / `highlight` / `fzf` | UI・設定・連携 | I/O |

置換は「実ファイルを触らず ripgrep に `--replace` させて `replacement` を得る」方式のため、
rust regex のキャプチャ展開が常に正確です。

## テスト

`plenary.nvim` を用いた headless テスト（純粋ロジックの網羅 + 実 ripgrep を叩く統合 + パネルのスモーク）。

```sh
make test        # 全 spec を実行（tests/deps/plenary.nvim を自動取得）
```

現在 **64 tests / 0 failures**。日本語（マルチバイト）のバイトオフセット、regex/リテラル、
glob include/exclude、キャプチャ参照置換、mtime 競合検知、デバウンス、パネルの
検索→折りたたみ→置換プレビュー→適用までを検証しています。

> 補足: `PlenaryBustedDirectory` は本環境の headless 実行で子ジョブがハングしたため、
> 同等の in-process ランナー（`tests/run.lua`）を使っています。
