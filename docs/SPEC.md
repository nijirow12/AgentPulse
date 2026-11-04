# AgentPulse — 要件定義

macOS のメニューバー常駐アプリ。裏で動いている AI コーディング CLI / ハーネスが「今何をしているか」と、
Claude / GPT(Codex) / OpenCode Go の使用量リミットを 1 つのポップオーバーで確認できる。

## 1. 対象と前提

- macOS 14 以降、Apple Silicon。Swift 6 toolchain（`swift build`）でビルド。Xcode プロジェクトは作らない。
- SwiftPM の executable target + SwiftUI `MenuBarExtra(.window)`。Dock には出さない（`LSUIElement=true`）。
- 外部依存パッケージなし（Foundation / SwiftUI / AppKit / SQLite3(system lib `import SQLite3`) のみ）。
- すべてローカルで完結。ネットワークアクセスは Claude の usage API 1 本のみ。

## 2. 機能要件

### F1. メニューバー表示
- アイコン（SF Symbol `waveform.path.ecg`）＋ 短いテキスト。
  - テキスト = 稼働中エージェント数と、全プロバイダの最大使用率。例: `2 · 88%`
  - 最大使用率が 80% 以上ならオレンジ、95% 以上なら赤（テキスト色はメニューバーで効かないので、アイコンを `exclamationmark.triangle.fill` に切替でも可）。
- クリックで幅 420pt 程度のポップオーバー（`MenuBarExtra` の `.window` スタイル）。

### F2. ポップオーバー構成（上から）
1. **ヘッダ**: アプリ名、最終更新時刻、手動リフレッシュボタン。
2. **Limits セクション**: プロバイダごとのカード（Claude / Codex (GPT) / OpenCode Go）。
   - 各ウィンドウ（5h, 7d など）を 1 行: ラベル、プログレスバー、`%`、リセットまでの残り時間（`2h 13m`）。
   - 取得失敗時はカード内にエラーメッセージ（灰色・1 行）を出し、他のカードは表示を続ける。
   - データの鮮度（いつの値か）を小さく表示（Codex はログ由来なので古い可能性がある）。
3. **Activity セクション**: 稼働中/最近動いたセッションの一覧。
   - 1 行 = ツール名バッジ（Claude / Codex / OpenCode / DSH）、作業ディレクトリ名（末尾 1 要素）、
     「今やっていること」1 行（例: `Bash: npm test`、`Edit: src/App.tsx`、`考え中…`、テキスト冒頭 80 文字）、
     最終更新からの経過（`12s ago`）。
   - 状態ドット: 緑 = 30 秒以内に更新 / 黄 = 5 分以内 / 灰 = それ以上（10 分超は一覧から除外）。
   - プロセスが生きているかどうかは別表示（`ps` 由来、PID と CPU%）。ログはあるがプロセスなしでも表示する。
   - 行クリックでその作業ディレクトリを Finder で開く。
4. **フッタ**: 「設定…」「終了」。

### F3. 更新
- Activity: 5 秒ごと。Limits: 60 秒ごと（Claude API は 60 秒未満で叩かない）。
- 収集はバックグラウンド（`Task.detached` / actor）で行い、UI スレッドをブロックしない。

### F4. 設定（`UserDefaults`、シンプルな設定ウィンドウ）
- OpenCode Go の上限ドル額（5h / 週 / 月）。デフォルト `12 / 30 / 60`（USD）。
- 各プロバイダの表示 ON/OFF。
- Activity の除外閾値（デフォルト 10 分）。

## 3. データソース仕様（実機で確認済み）

### D1. Claude（サブスク使用率）
- 認証情報（読み取り専用・書き込み/リフレッシュ禁止）: `~/.claude/.credentials.json` があればそれ、なければ `security find-generic-password -s "Claude Code-credentials" -w` の stdout（どちらも同じ JSON）。
  `claudeAiOauth.accessToken` を使う（`Process` で `/usr/bin/security` を実行）。
- `GET https://api.anthropic.com/api/oauth/usage`
  - Header: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`
  - レスポンスはトップレベルに `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet` 等のキー。
    値が `{ "utilization": <0-100 の数値>, "resets_at": <ISO8601 文字列 or null> }` の形のものを
    **キー名に依らず汎用的に**ウィンドウとして表示（null 値はスキップ）。ラベルはキー名を整形（`five_hour`→`5h`, `seven_day`→`7d`, `seven_day_opus`→`7d Opus`）。
- トークンはログ・UI に出さない。401 の場合は「Claude Code で再ログインしてください」を表示。

### D2. Codex / GPT（使用率）
- **一次ソース（ライブ）**: `GET https://chatgpt.com/backend-api/wham/usage`（Codex の `/status` と同じ経路）。
  - 認証: `~/.codex/auth.json` の `tokens.access_token` を Bearer、`tokens.account_id` を `ChatGPT-Account-Id` ヘッダーに。**読み取り専用**（リフレッシュ・書き戻しはしない。JWT の `exp` が過ぎていたら要求しない）。
  - 応答 `rate_limit.primary_window` / `secondary_window` の `used_percent`, `limit_window_seconds`, `reset_at`(UNIX 秒)。
- **予備（オフライン時など）**: 以下のログから取得し、その旨を注記する。
- `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`。更新日時が新しい順に最大 5 ファイルを見て、
  末尾から `"rate_limits"` を含む行を探す（ファイル末尾 512KB だけ読めばよい）。
- 該当行は JSON。`payload.rate_limits`（なければ再帰的に `rate_limits` キーを探す）:
  ```json
  {"primary":{"used_percent":25.0,"window_minutes":300,"resets_at":1793530957},
   "secondary":{"used_percent":88.0,"window_minutes":10080,"resets_at":1793780859},
   "plan_type":"plus"}
  ```
  - `window_minutes` 300→`5h`, 10080→`7d`、それ以外は `Nh`/`Nd` で表記。`resets_at` は UNIX 秒。
  - `resets_at` を過ぎていたら使用率 0% 扱い＋「リセット済み（最新値未取得）」と注記。
  - 鮮度 = その行のファイルの更新時刻。

### D3. OpenCode Go
- **一次ソース（正確な値）**: opencode 常駐サービスの `GET http://127.0.0.1:<port>/api/experimental/usage/limits`。
  - 接続情報は `~/.config/opencode/service.json` の `port` / `password`（**読み取り専用**）。Basic 認証（ユーザー名 `opencode`）。
  - 応答 `data.go.{rolling,weekly,monthly}` の `percent`, `limited`, `resetsAt`(ms) を 5h / 7d / 月 として表示。DSH の利用も含まれる。
  - `data` が null = OpenCode Console 未サインイン（`opencode auth login opencode`）。この場合と接続失敗時は以下の推定に戻し、理由を注記する。
- **予備（推定）**:
- SQLite: `~/.local/share/opencode/opencode.db`（WAL。**読み取り専用**で開く: `sqlite3_open_v2(..., SQLITE_OPEN_READONLY)`、`?immutable` は使わない）。
- テーブル `session_message`（`type='assistant'`）の `data` JSON:
  `model.providerID == "opencode-go"`, `model.id`, `tokens.input`, `tokens.output`, `tokens.reasoning`, `tokens.cache.read`, `tokens.cache.write`, `time.created`(ms)。
  旧テーブル `message` も同形式（`providerID`, `modelID` がトップレベル）なので両方集計。
- 料金: `kv` テーブルの key=`models-dev:v2:catalog` の `value` JSON → `body`（文字列なら再度 JSON パース）→
  `["opencode-go"]["models"][modelId]["cost"]["text"]` に `input.price`, `input.cache.read`, `output.price`（USD / 1M tokens）。
  multipliers は無視してよい。reasoning は output 単価、cache.write は input 単価で計算。
- ウィンドウ: 直近 5 時間 / 7 日 / 30 日の推定コスト合計 ÷ 設定上限 = 使用率。ラベルに「推定」と明記。
- DSH（DeepSeek Harness）も `opencode-go` を使うが、ローカル DB に記録されないので推定に含まれない旨を注記。

### D4. Activity（今何をしているか）
各ソースから「セッション」の配列を作る: `tool, sessionId, cwd, lastUpdate, summary, isProcessAlive`。

- **プロセス**: `/bin/ps -axo pid=,pcpu=,etime=,command=` をパース。
  - `claude`（コマンド先頭のバイナリ名が `claude`、または `claude-code` を含む）、
    `codex`、`opencode`、`dsh/lib/bin.js` を含む `node` をそれぞれ検出。
  - 作業ディレクトリは `lsof -a -d cwd -p <pid> -Fn` で取得（失敗時は不明）。
- **Claude Code**: `~/.claude/projects/*/*.jsonl` のうち直近 10 分以内に更新されたもの。
  末尾 64KB を読み、最後の `type=="assistant"` 行の `message.content[]` の最後の要素:
  `tool_use` なら `"<name>: <入力要約>"`（`command` / `file_path` / `pattern` / `description` の順で最初にあるもの）、
  `text` なら冒頭 80 文字、`thinking` なら `考え中…`。`cwd` は行の `cwd` フィールド。
- **Codex**: `~/.codex/sessions/**/rollout-*.jsonl` で 10 分以内更新のもの。末尾から
  `payload.type` が `function_call`（`name` + `arguments` 要約）/ `agent_message` / `reasoning` の最後を要約。
  `cwd` は `session_meta` / `turn_context` 行の `payload.cwd`（先頭 16KB から取得）。
- **OpenCode**: `session_message` を `time_created > now-10min` で取得し `session_id` ごとに最新行。
  `session_v2.directory` を cwd に。assistant の `content` 最後の要素（`type` が `tool` なら tool 名、`text` / `reasoning` は冒頭）。
- **DSH**: `~/.dsh/sessions/*/session-*/session.v4.jsonl.zstd` で 10 分以内更新のもの。
  `/opt/homebrew/bin/zstd -dc` で展開した末尾数行から最後のイベントの型/テキストを要約（失敗時は「実行中」だけ）。
  ディレクトリ名 `--Users-foo-bar--` → cwd `/Users/foo/bar`（ベストエフォート）。
- パース失敗は握りつぶしてその行だけスキップ（アプリを落とさない）。

## 4. 非機能要件
- CPU: アイドル時 1% 未満を目標。大きなファイルは末尾だけ読む（`FileHandle.seek`）。
- 秘密情報（トークン）をログ出力・ファイル保存しない。
- コードは Swift 6 strict concurrency で警告なしを目標（最低限ビルドが通ること）。

## 5. 成果物
- `Package.swift`, `Sources/AgentPulse/*.swift`
- `scripts/build_app.sh`: `swift build -c release` → `build/AgentPulse.app`（Info.plist に `LSUIElement`, `CFBundleIdentifier=local.agentpulse`）を生成し ad-hoc 署名（`codesign -s -`）。
- `Tests/AgentPulseTests`: パーサ（Codex rate_limits / Claude usage JSON / Claude jsonl 要約 / OpenCode コスト計算）の単体テスト（フィクスチャ文字列で）。
- `README.md`: ビルド・起動方法、データソース、制約。
