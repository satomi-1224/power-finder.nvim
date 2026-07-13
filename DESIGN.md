# search-ui.nvim 設計ドキュメント

> Zed / IntelliJ の "Find in Files / Find in Path" 相当の、強力なプロジェクト検索・置換 UI を Neovim 上に実装するための設計書。

作成日: 2026-07-13
対象環境: Neovim 0.12.3 / lazy.nvim / ripgrep 15.1.0 / macOS

---

## 0. ヒアリング結果サマリ

| 項目 | 決定 |
| --- | --- |
| 実装の土台 | **fzf-lua を活かす**(新規finderの二重管理は避けたい) |
| UI 形態 | **提案希望** → 本書 §4 で確定案を提示 |
| 一括置換 | **必須**(Search & Replace across files) |
| 置換ワークフロー | **diff プレビュー → チェックで一括適用** |
| 画面構成 | **一体型パネル**(上部フォーム + 下部結果、ライブ更新) |
| 実行タイミング | **ライブ**(入力ごとに ripgrep 再実行) |
| 必須フィルタ | 正規表現/リテラル切替・case/word・include/exclude glob・スコープ指定 |
| 履歴/プリセット | 不要 |

---

## 1. コンセプトとゴール

「検索条件を構造化フォームで組み立て、結果をライブで見ながら絞り込み、必要なら
diff を確認して一括置換する」という、IDE 級の検索体験を Neovim ネイティブで提供する。

参照プロダクトと本プラグインの対応:

| 参照 | 借りる要素 |
| --- | --- |
| **Zed** Project Search | 検索/Include/Exclude の入力欄、regex/case/word のトグル、diff 確認付き置換 |
| **IntelliJ** Find in Path | スコープ指定(Project/Directory/Open files/Custom path)、file mask |
| **grug-far.nvim** | 一体型バッファ(条件も結果も1バッファ)、ライブ更新、結果バッファ編集の思想 |
| **fzf-lua** | パス/ディレクトリ選択の補助 picker、プレビュー、devicons、既存の操作感 |

---

## 2. 最重要の設計判断: fzf-lua の位置づけ

### 2.1 直面する矛盾

ヒアリングで **「fzf-lua を土台に」** と **「一体型パネル + ライブ + diff プレビュー置換」**
の両方が選ばれた。この2つは技術的に両立しにくい:

- fzf-lua は「**単一プロンプト**にクエリを打ち、外部 `fzf` プロセスでファジー絞り込みする」モデル。
- 「複数入力欄のフォーム」「結果を編集可能バッファに展開」「行単位の diff チェックボックス」は、
  fzf の TUI では表現できない(fzf は1行1アイテムの選択 UI であって、任意レイアウトの描画面ではない)。

つまり **一体型パネル UI を選んだ時点で、メインの検索面を fzf-lua で作ることはできない。**

### 2.2 解決方針（推奨）

**コアの一体型パネルは Neovim の通常バッファ + フローティング/分割ウィンドウで自作**し、
**fzf-lua は「補助 picker」として統合**する。これで両方の要望を最大限満たす:

| 役割 | 担当 | 理由 |
| --- | --- | --- |
| 検索条件フォーム | 自作(通常バッファ) | 複数入力欄・トグルは fzf で作れない |
| 結果リスト表示 | 自作(通常バッファ) | ファイルグルーピング・折りたたみ・diff チェックが必要 |
| ライブ ripgrep 実行 | 自作(`vim.system`) | デバウンス/キャンセル制御が必要 |
| プレビュー | 自作 or fzf-lua の previewer 流用 | 既存資産を活かす |
| **スコープの "任意パス/ディレクトリ" 選択** | **fzf-lua** | ディレクトリ picker として最適 |
| **include/exclude glob のファイル候補選択** | **fzf-lua** | ファイルツリーから glob を組む補助に最適 |
| devicons / カラー | nvim-web-devicons(fzf-lua と共有) | 見た目の一貫性 |

> **要確認**: この「fzf-lua は補助 picker」という落とし所で良いか。
> もし「検索面そのものを fzf-lua でやりたい(一体型パネルは諦める)」なら §11 の代替案 B に切り替える。

---

## 3. アーキテクチャ全体像

```
                         :SearchUI  (ユーザーコマンド / キーマップ)
                              │
                              ▼
        ┌──────────────────────────────────────────────┐
        │                  panel.lua                    │  ← 一体型パネル(UI統括)
        │  ┌────────────┐          ┌─────────────────┐  │
        │  │ form 領域   │          │ results 領域     │  │
        │  │ (条件入力)  │          │ (結果/diff描画)  │  │
        │  └─────┬──────┘          └────────▲────────┘  │
        └────────│──────────────────────────│───────────┘
                 │ 条件が変わるたび          │ 描画
                 ▼                          │
        ┌──────────────┐   rg args   ┌──────┴───────┐
        │  engine.lua  │────────────▶│  search.lua  │  vim.system(rg --json)
        │ (rgコマンド   │             │ (実行/パース  │  デバウンス&キャンセル
        │  組み立て)    │             │  /結果モデル) │
        └──────────────┘             └──────┬───────┘
                                            │ Match[]
                                            ▼
                                    ┌──────────────┐
                                    │ results.lua  │  ファイル単位グルーピング
                                    │ (モデル&描画) │  折りたたみ・ハイライト
                                    └──────┬───────┘
                                           │ 置換要求
                                           ▼
                                    ┌──────────────┐
                                    │ replace.lua  │  diffプレビュー生成
                                    │              │  チェック済みを一括適用
                                    └──────────────┘

  補助: fzf.lua … スコープ/globのパス選択picker(fzf-lua委譲)
        config.lua / highlight.lua / util.lua
```

---

## 4. UI レイアウト（確定案）

一体型フローティングパネル。上部が条件フォーム、区切り線、下部が結果。

```
╭─ Search in Project ──────────────────────────────────────────╮
│ Search   │ handleRequest                          [.*] [Aa] [W] │  ← regex/case/word トグル
│ Replace  │ handleAsyncRequest                                    │  ← 置換文字列(空なら検索のみ)
│ Include  │ *.ts, *.tsx                                           │
│ Exclude  │ **/node_modules/**, **/dist/**                        │
│ Scope    │ ● Project  ○ Cwd  ○ Open buffers  ○ Path: …          │
├───────────────────────────────────────────────────────────────┤
│  128 matches in 23 files                          [rg 0.04s]    │  ← ステータス行
│                                                                 │
│ ▼ src/api/client.ts   (4)                                       │  ← ファイル見出し(折りたたみ可)
│    18 │  export function handleRequest(req) {                    │
│    45 │    return handleRequest(retry(req))                      │
│ ▶ src/api/server.ts   (2)                                       │  ← 折りたたみ中
│ ▼ src/handlers.ts   (1)                                         │
│   102 │  const h = handleRequest                                 │
╰───────────────────────────────────────────────────────────────╯
  <CR> open  ·  <Tab> fold  ·  <C-r> regex  ·  <C-c> case  ·  <C-w> word
  <C-s> scope picker  ·  <C-d> replace-preview  ·  q close
```

### 置換 diff プレビュー（`<C-d>` で遷移）

```
╭─ Replace Preview: handleRequest → dispatchRequest ───────────╮
│ [x] src/api/client.ts   (2 changes)                          │  ← [x]=適用対象 [ ]=除外
│    18 │- export function handleRequest(req) {                 │
│       │+ export function dispatchRequest(req) {               │
│    45 │-   return handleRequest(retry(req))                   │
│       │+   return dispatchRequest(retry(req))                 │
│ [ ] src/api/server.ts   (1 change)     ← Space で除外中        │
│    30 │-   handleRequest()                                    │
│       │+   dispatchRequest()                                  │
╰──────────────────────────────────────────────────────────────╯
  <Space> toggle file  ·  <C-a> all  ·  <C-x> none  ·  <CR> apply  ·  q cancel
```

- チェック単位は当面「ファイル単位」。行単位トグルは将来拡張（§10）。
- 適用は1 undo ブロック。適用後、変更ファイルはバッファに読み込み直し or `:checktime` で同期。

---

## 5. 検索エンジン仕様（engine.lua / search.lua）

### 5.1 ripgrep 呼び出し

- `vim.system({ 'rg', ... }, { text = true }, on_exit)` を使用（0.10+ の非同期 API）。
- 出力は **`--json`** を採用。理由: マッチ位置(column, byte offset)・複数行を正確に取得でき、
  ハイライトと置換の桁ずれを防げる。`--json` の各行を `vim.json.decode` してイベント
  (`begin` / `match` / `end` / `summary`)を処理。

### 5.2 条件 → rg 引数のマッピング

| フォーム項目 | rg 引数 |
| --- | --- |
| Search（regex ON） | `-e <query>`（既定は PCRE を使わず rust regex。必要なら `-P` オプション化） |
| Search（regex OFF） | `-F -e <query>`（固定文字列） |
| Case トグル | ON→`-s`（case sensitive） / OFF→`-i` / 既定→`-S`（smart-case） |
| Word トグル | `-w` |
| Include | 各パターンを `-g '<pat>'` |
| Exclude | 各パターンを `-g '!<pat>'` |
| Scope: Project | repo ルート（`git rev-parse --show-toplevel`、無ければ cwd） |
| Scope: Cwd | `vim.fn.getcwd()` |
| Scope: Open buffers | 開いている実ファイルのパス群を明示指定 |
| Scope: Path | fzf-lua のディレクトリ picker で選んだパス |
| 常時 | `--json --column --line-number --no-heading -M 4096`（長大行の暴走防止） |

- `.gitignore` は既定で尊重（rg デフォルト）。`--hidden` / `--no-ignore` は設定/トグルで切替可能に。

### 5.3 ライブ実行の制御

- **デバウンス**: 入力停止から既定 120ms（`config.debounce_ms`）で実行。
- **キャンセル**: 新しい検索が走る前に、進行中の `vim.system` ハンドルを `:kill()`。
- **最小クエリ長**: 既定1文字未満は実行しない（`config.min_query`）。
- **上限**: 結果件数/ファイル数に上限（既定 10000 マッチ）。超過時はステータスに明示（"showing first N"）。
- **プロセス多重起動防止**: 世代カウンタ(generation id)で古い結果を破棄。

---

## 6. 結果モデル（results.lua）

```lua
---@class SearchMatch
---@field path string           -- 相対パス
---@field lnum integer          -- 1-based 行番号
---@field col integer           -- 1-based 桁(バイト→表示桁へ変換)
---@field text string           -- マッチ行テキスト
---@field submatches { start:integer, finish:integer }[]  -- 行内マッチ範囲(バイト)

---@class SearchFile
---@field path string
---@field matches SearchMatch[]
---@field collapsed boolean
```

- ファイル単位でグルーピング。見出し行 `▼/▶ path (count)`。
- extmark でマッチ部分をハイライト、行番号は仮想テキスト or サインカラムに寄せる。
- バッファは `modifiable=false`（結果は原則読み取り専用。置換は別ビューで）。
- 行 → `(path, lnum)` の対応表を保持し、`<CR>` で元ファイルの当該位置へジャンプ。

---

## 7. 置換ワークフロー（replace.lua）

1. `<C-d>` で置換モードに入る（`Replace` 欄は置換モードでのみ編集可）。置換文字列を入力すると
   diff がライブで再生成される。
2. 置換文字列の解釈:
   - regex ON なら `$1`/`${name}` などのキャプチャ参照を許可（rg の `--replace` 相当のロジックを
     自前実装、または各マッチに対し Lua/vim regex で算出）。
   - regex OFF ならリテラル置換。
3. **プレビューは実ファイルを書き換えず**、メモリ上で「置換後行」を生成し diff 表示。
4. ファイル単位チェックボックス（`[x]/[ ]`）で対象を選別。
5. `<CR>` で適用:
   - 各対象ファイルを読み込み、対象行のみ置換 → 書き戻し。
   - 開いているバッファは `nvim_buf_set_lines` で更新し undo 履歴を保持、
     未オープンはファイル I/O。全体を1操作としてまとめ、`SearchUIReplaceUndo` で戻せるよう記録。
6. 適用結果をステータスに要約（"Replaced 42 occurrences in 12 files"）。

**安全策**:
- 適用前に各ファイルの mtime を記録し、直前に外部変更があれば警告して中断。
- ドライラン結果と実適用でマッチ数が食い違ったら中断（ファイルが変わった証拠）。

---

## 8. キーマップ（既定案・設定で上書き可）

| コンテキスト | キー | 動作 |
| --- | --- | --- |
| グローバル | `<leader>sf` | パネルを開く(`:SearchUI`) |
| フォーム | `<C-r>` / `<C-c>` / `<C-w>` | regex / case / word トグル |
| フォーム | `<C-s>` | スコープ picker(fzf-lua) |
| フォーム | `<Tab>` / `<S-Tab>` | 次/前の入力欄へ |
| 結果 | `<CR>` | 該当箇所を開く（パネルは開いたまま or 閉じる: 設定） |
| 結果 | `<Tab>` | ファイル折りたたみトグル |
| 結果 | `<C-q>` | 結果を quickfix に送る（既存ワークフローとの橋渡し） |
| 結果/フォーム | `<C-d>` | 置換プレビューへ |
| プレビュー | `<Space>` / `<C-a>` / `<C-x>` | 対象トグル / 全選択 / 全解除 |
| プレビュー | `<CR>` | 適用 |
| 全体 | `q` / `<Esc>` | 閉じる |

---

## 9. モジュール構成 / ディレクトリ

```
search-ui.nvim/
├── README.md
├── DESIGN.md                      ← 本書
├── plugin/
│   └── search-ui.lua              -- コマンド/デフォルトキーマップ登録(遅延ロード配慮)
├── lua/
│   └── search-ui/
│       ├── init.lua               -- setup(), open(), 公開API
│       ├── config.lua             -- デフォルト設定 + マージ
│       ├── panel.lua              -- 一体型パネルのウィンドウ/バッファ統括
│       ├── form.lua               -- 条件フォームの描画・入力・トグル状態
│       ├── engine.lua             -- 条件 → rg 引数の組み立て
│       ├── search.lua             -- vim.system 実行・--json パース・デバウンス/キャンセル
│       ├── results.lua            -- 結果モデル・グルーピング・描画・ハイライト
│       ├── replace.lua            -- 置換算出・diff プレビュー・一括適用
│       ├── fzf.lua                -- fzf-lua 連携(スコープ/glob picker)
│       ├── highlight.lua          -- ハイライトグループ定義
│       └── util.lua               -- 共通ユーティリティ
└── tests/                         -- busted/plenary によるテスト(engine/replace が中心)
```

---

## 10. 設定 API（案）

```lua
require('search-ui').setup({
  keymaps = { open = '<leader>sf' },
  layout = {
    style = 'float',            -- 'float' | 'split'
    width = 0.8, height = 0.85, -- float 時の割合
  },
  search = {
    debounce_ms = 120,
    min_query = 1,
    max_results = 10000,
    smart_case = true,          -- case トグル未指定時の既定
    respect_gitignore = true,
    hidden = false,
    max_columns = 4096,
  },
  defaults = {                  -- 起動時の初期条件
    include = '',
    exclude = '**/.git/**',
    scope = 'project',          -- 'project'|'cwd'|'buffers'|'path'
    regex = true, case = false, word = false,
  },
  fzf = {
    use_for_scope_picker = true,
    use_for_glob_picker = true,
  },
  replace = {
    confirm_unit = 'file',      -- 'file'(初期実装) | 'hunk'(将来)
    reload_open_buffers = true,
  },
})
```

---

## 11. 代替アーキテクチャ（保険）

- **案 A（推奨・本書のベース）**: 自作一体型パネル + fzf-lua 補助 picker。
  望む UI を全て満たす。実装量は中〜大。
- **案 B（fzf-lua 全面依存）**: 検索面を fzf-lua の `live_grep` + `rg_glob` に寄せ、
  条件は fzf のプロンプト構文（`-- --glob ...`）で渡す。置換は結果を quickfix→`cdo` に流す。
  → 一体型パネル・diff プレビューは**実現不可**。実装は最小。
  「UI のリッチさより手軽さ・既存踏襲」を優先する場合のみ。
- **案 C（既存プラグイン採用）**: `grug-far.nvim` を導入して設定でカスタマイズ。
  望む UI にほぼ一致し実装ゼロだが、「自作したい/fzf-lua 土台」の意図とは外れる。
  → 学習/カスタム目的でなければ最有力の"作らない"選択肢。**要判断**。

---

## 12. 実装ロードマップ

- **M0 スケルトン**: ディレクトリ・`setup`・`:SearchUI` でパネルが開くだけ。
- **M1 ライブ検索**: フォーム(Search のみ)→ rg --json → 結果グルーピング表示・ジャンプ。
- **M2 フィルタ**: regex/case/word トグル、include/exclude glob、スコープ(project/cwd/buffers)。
- **M3 fzf-lua 連携**: スコープの任意パス picker、glob 候補 picker。
- **M4 置換**: Replace 欄 → diff プレビュー → ファイル単位チェック → 一括適用 + undo/安全策。
- **M5 仕上げ**: quickfix 連携、設定 API 整備、ハイライト調整、パフォーマンス、テスト。
- **M6 拡張**: 行単位 diff チェック、`--hidden`/`--no-ignore` トグル、multiline 検索。

---

## 13. リスク / 要検討事項

1. **fzf-lua の役割**（§2.2）: 「補助 picker」で合意できるか。ここが全体を左右する最重要点。
2. **置換の安全性**: 外部編集・エンコーディング・巨大ファイル・シンボリックリンク。mtime チェックで担保。
3. **性能**: 大規模 repo でのライブ更新。デバウンス+キャンセル+件数上限で対処。
4. **regex 方言**: rust regex(rg 既定) と Vim regex の差。UI は rg 基準で統一し、その旨を明示。
5. **桁ずれ**: `--json` のバイトオフセット → 表示桁/extmark 変換。マルチバイト日本語で要検証。
6. **nix 環境**: 設定は home-manager 管理。開発は本作業ディレクトリで行い、
   完成後に home-manager の lazy スペックへ組み込む（`dir = '...'` のローカル参照 or リポジトリ化）。

---

## 次のアクション（要判断ポイント）

- [ ] §2.2「fzf-lua は補助 picker」で確定してよいか（案A/B/C の選択）
- [ ] 案 C(grug-far 採用)を検討対象に含めるか、あくまで自作するか
- [ ] 確定後、M0 スケルトン生成 → M1 から実装着手
