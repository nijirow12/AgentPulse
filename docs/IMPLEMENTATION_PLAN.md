# AgentPulse — 実装手順

SPEC.md を必ず先に読むこと。各ステップの最後に `swift build` が通る状態を保つ。

## Step 1. パッケージ骨格
- `Package.swift`（swift-tools-version 6.0, platforms `.macOS(.v14)`）
  - executableTarget `AgentPulse`（`linkerSettings: [.linkedLibrary("sqlite3")]`）
  - testTarget `AgentPulseTests`（依存: `AgentPulse`。テストしやすいよう、パーサは `AgentPulseCore` という library target に分けてもよい。その場合 executable は Core に依存）
- `AgentPulseApp.swift`: `@main struct AgentPulseApp: App` に `MenuBarExtra { PopoverView() } label: { MenuBarLabel() }.menuBarExtraStyle(.window)` と `Settings { SettingsView() }`。
- 起動時 `NSApp.setActivationPolicy(.accessory)`。

## Step 2. モデル（Core）
```swift
struct UsageWindow: Identifiable, Sendable { id, label: String, usedPercent: Double, resetsAt: Date?, note: String? }
struct ProviderUsage: Identifiable, Sendable { id: ProviderKind, windows: [UsageWindow], asOf: Date?, error: String?, footnote: String? }
enum ProviderKind: String { case claude, codex, opencodeGo }
enum AgentTool: String { case claude, codex, opencode, dsh }
struct AgentSession: Identifiable, Sendable { id: String, tool: AgentTool, cwd: String?, lastUpdate: Date, summary: String, pid: Int32?, cpu: Double? }
```

## Step 3. 共通ユーティリティ（Core）
- `FileTail.read(url, maxBytes) -> String`（末尾だけ読み、先頭の不完全行を捨てる）
- `Shell.run(path, args, timeout) -> (status, stdout)`（`Process` + `Pipe`、タイムアウト 5 秒）
- `SQLiteReader`（read-only open、`query(sql) -> [[String: Any?]]` 程度の薄いラッパ。`sqlite3_busy_timeout` 1000ms）
- `Duration` 表示ヘルパ: `2h 13m`, `12s ago`。

## Step 4. Limits プロバイダ（Core、各々 純粋なパース関数 + I/O 関数に分ける）
- `ClaudeUsage.parse(data) -> [UsageWindow]` / `ClaudeUsage.fetch() async -> ProviderUsage`
- `CodexUsage.parse(line) -> [UsageWindow]?` / `CodexUsage.load() -> ProviderUsage`
- `OpenCodeGoUsage.cost(tokens, price) -> Double` / `OpenCodeGoUsage.load(limits) -> ProviderUsage`

## Step 5. Activity コレクタ（Core）
- `ProcessScanner.scan() -> [ProcInfo]`（ps パース + lsof cwd。lsof は対象 PID だけ）
- `ClaudeActivity.collect()`, `CodexActivity.collect()`, `OpenCodeActivity.collect()`, `DSHActivity.collect()`
- `ActivityAggregator`: 上記を統合、プロセス情報を cwd 一致（または tool 一致で唯一）で紐づけ、ログのないプロセスも 1 行として出す。lastUpdate 降順。
- `summarize(toolName:input:)` の共通関数（SPEC D4 のフィールド優先順）

## Step 6. 状態管理（App）
- `@MainActor final class AppModel: ObservableObject`: `@Published usages`, `sessions`, `lastRefresh`。
- 2 つの `Task` ループ（5 秒 / 60 秒）。収集は `Task.detached` で実行し結果だけ MainActor に戻す。
- `refreshNow()`。

## Step 7. UI（App）
- `MenuBarLabel`: アイコン + `"\(active) · \(maxPct)%"`。
- `PopoverView`: SPEC F2 のとおり。`ScrollView` 最大高 520。
- `ProviderCard`, `UsageRow`（`ProgressView(value:)` + 色: <80 緑 / <95 オレンジ / それ以上 赤）, `SessionRow`。
- `SettingsView`: OpenCode Go 上限 3 つ、プロバイダ表示トグル、除外閾値。`@AppStorage`。
- 「終了」は `NSApp.terminate(nil)`。

## Step 8. テスト
- フィクスチャ文字列で: Codex rate_limits 行 → 5h 25% / 7d 88%、Claude usage JSON → five_hour/seven_day、
  Claude jsonl 末尾 → `Bash: npm test` 要約、OpenCode コスト計算。`swift test` が通ること。

## Step 9. パッケージング
- `scripts/build_app.sh`（`set -euo pipefail`）: release ビルド → `build/AgentPulse.app/Contents/{MacOS,Info.plist}` → `codesign --force -s - build/AgentPulse.app`。
- README.md。

## 完了条件
- `swift build` と `swift test` が成功。
- `scripts/build_app.sh` で `build/AgentPulse.app` ができ、`open build/AgentPulse.app` でメニューバーに出る。
