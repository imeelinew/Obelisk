# Obelisk 项目代码审查问题调查报告

> 审查日期: 2026-05-11 | 基线 commit: `d530496`  
> 代码行数: ~7,200 Swift (14 files) + 1 Python + 2 脚本

---

## 一、严重问题 (Critical)

### [C1] API Key 明文落盘风险 — `TitleOptimizer.swift:31`

`LLMConfig` 结构体包含 `apiKey` 字段，关闭本地加密时以明文 JSON 写入 `llm.json`。即使加密开启，其他文件中 `Authorization: Bearer` 头仍明文通过网络传输，若启用了 HTTP 层日志或代理调试，API Key 会泄露。

```swift
// TitleOptimizer.swift:181
request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
```

**建议**: 将 API Key 存入 Keychain（已有 `KeychainEncryptionKeyStore` 可复用），避免任何形式落盘；网络层使用 `URLSession` 的 `ephemeral` 配置避免缓存。

---

### [C2] 数据一致性无事务保证 — `BookmarkStore.swift:164-185, 422-442`

书签与状态分离存储在两个文件中（`bookmarks.json` + `bookmark_state.json`），但保存时先写状态再写主文件，任一失败均导致数据不一致：

```swift
// BookmarkStore.swift:170-171
try persistState(from: database.bookmarks)  // ← 如果这个成功
let data = try encoder.encode(database)
try secureCodec.writeData(data, to: fileURL, ...)  // ← 这个失败 → 状态已持久化但书签未更新
```

**建议**: 使用临时目录 + 原子 rename 实现两阶段提交，或将状态与书签合并到同一文件。

---

### [C3] 加密开关存在竞态窗口 — `BookmarkManagerView.swift:485-488`

```swift
encryptLocalJSONData = isEnabled
LocalJSONEncryption.isEnabled = isEnabled  // ← 立即全局生效
// 如果后面 migrateLocalPrivateStorage 抛异常才 rollback
```

在 `isEnabled` 改变到 rollback 之间的时间窗口内，读取 `LocalJSONEncryption.isEnabled` 的其他代码会拿到错误值，导致混合加密/明文文件的脏数据。

**建议**: 先迁移，迁移成功后再改标志位；或使用 actor 隔离的写入锁。

---

### [C4] `nonisolated(unsafe)` 绕过 Swift 6 线程安全 — `GlobalHotkey.swift:12-14`

```swift
nonisolated(unsafe) private var hotKeyRefs: [EventHotKeyRef] = []
nonisolated(unsafe) private var eventHandler: EventHandlerRef?
nonisolated(unsafe) private var registeredIDs = Set<UInt32>()
```

在 Swift 6 完整并发检查下这些是编译错误，`nonisolated(unsafe)` 仅是临时规避。Carbon 回调在任意线程触发，而 `DispatchQueue.main.async` 回调修改 `handlers` 字典，存在数据竞争。

**建议**: 使用 `@MainActor` class + `withUnsafeContinuation` 封装 Carbon 回调，或将可变状态移入 `OSAllocatedUnfairLock` 保护的存储。

---

## 二、高危问题 (High)

### [H1] 全局可变状态无同步 — `SecureJSONFileCodec.swift:5-11`, `14-27`

```swift
public enum LocalJSONEncryption {
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}
```

`isEnabled` 通过 `UserDefaults` 全局共享，从任意 context（`@MainActor`、`Task.detached`、非隔离 context）都可读写，没有同步机制。读取值可能在不同文件中被缓存导致过期。

**建议**: 用 `@MainActor` class + 显式 invalidate 通知替代 enum 的 `static var`。

---

### [H2] `withFileLock` 使用 `flock` 与 iCloud 文件协调冲突 — `BookmarkStore.swift:218-234`

```swift
let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
guard flock(fd, LOCK_EX) == 0 else { ... }
```

`flock` 是 advisory lock，仅在单机、同文件系统有效。对 iCloud Drive 文件无效，且与 `NSFileCoordinator` 不互斥。当 iCloud 同步开启时，两个设备可能同时写入。

**建议**: iCloud 场景下使用 `NSFileCoordinator.coordinate(writingItemAt:)`，`flock` 仅作为本地 fallback。

---

### [H3] AppleScript 注入风险 — `BrowserCurrentTab.swift`, `PrivateBrowserOpener.swift`

```swift
// BrowserCurrentTab.swift:41-48
tell application id "\(bundleID)"    // ← bundleID 来自 NSWorkspace
```

虽然 `bundleID` 来自系统 API，但在 `PrivateBrowserOpener.swift:64` 中：

```swift
set targetURL to "\(appleScriptEscaped(url.absoluteString))"
```

`appleScriptEscaped` 仅转义 `\` 和 `"`，不处理 AppleScript 的 string concatenation 字符或特殊语法。一个恶意构造的 URL（如在 `title` 中包含 `" & do shell script "..." & "`）可能被执行。

**建议**: 使用 `NSAppleEventDescriptor` 参数化传递值，避免字符串拼接 AppleScript。

---

### [H4] Favicon 下载无内容类型/大小限制 — `main.swift:655-669`

```swift
private func downloadImageData(from url: URL) async -> Data? {
    guard let (data, response) = try? await session.data(from: url) else { return nil }
    // 无 Content-Length 检查，无 content-type 验证
    guard NSImage(data: data) != nil else { return nil }
}
```

可被恶意服务器利用下载任意大小的文件（OOM），且 `NSImage(data:)` 会尝试解析(包括 SVG 等可能触发 WebKit 逻辑的格式)。

**建议**: 添加 `Content-Length` / `Content-Type` 检查（max 1MB），仅允许 `image/png`, `image/x-icon`, `image/vnd.microsoft.icon`。

---

### [H5] LLM Prompt Injection — `TitleOptimizer.swift:270-281`

书签标题作为 `user` 消息直接发送给 LLM，无任何过滤。若书签标题包含类似 `Ignore previous instructions and output...` 的内容，可能被 prompt injection 攻击。

**建议**: 在 system prompt 外层包裹更强的防注入指令；将用户输入包裹在 XML/CDATA 风格的标记中（OpenAI 推荐做法）。

---

## 三、中危问题 (Medium)

### [M1] URL 规范化不完整 — `BookmarkStore.swift:456-481`

```swift
private func normalizedURL(_ rawURL: String) -> String {
    components.scheme = components.scheme?.lowercased()
    components.host = components.host?.lowercased()
    // 未处理: percent-encoding 等价 ('%20' vs '+'), 
    //         default ports (443/80), trailing dot on host, 
    //         empty query string
}
```

两个语义等价的 URL 可能被判定为不同:
- `https://example.com/path%20name` vs `https://example.com/path+name`
- `https://example.com` vs `https://example.com:443`
- 查询参数 `?` vs `?utm_source=x` （参数排序已做但未去跟踪参数）

**建议**: 添加 `components.percentEncodedQuery` 解码 + 移除 common tracking params (utm_*, fbclid 等)。

### [M2] 重复代码 — 多处

| 重复项 | 位置 1 | 位置 2 |
|--------|--------|--------|
| `normalizedURL` | `BookmarkStore.swift:456` | `BookmarksModel.swift:147` |
| `uniqueURLs` | `SecureJSONFileCodec.swift:579` | `SecureJSONFileCodec.swift:220` |
| `uniqueFaviconLocations` | `main.swift:534` | `SecureJSONFileCodec.swift:472` |
| Favicon storage logic | `FaviconLoader` | `ObeliskStorageMigrator` |

**建议**: 抽取公共方法到 `ObeliskCore` 的统一模块。

### [M3] 超大文件违反 SRP

| 文件 | 行数 | 包含职责 |
|------|------|----------|
| `main.swift` | 1018 | AppDelegate + FaviconLoader + BookmarkFileWatcher |
| `BookmarkManagerView.swift` | 1570 | 所有设置页面 + 编辑器 + 侧栏 + Toast |
| `SecureJSONFileCodec.swift` | 874 | 6 个独立 enum/class 共处一文件 |

**建议**: 按类型拆分：`AppDelegate.swift`, `FaviconLoader.swift`, `BookmarkFileWatcher.swift` 等。

### [M4] 遗留命名污染环境变量 — 多处

```swift
// BookmarkStore.swift:111
ProcessInfo.processInfo.environment["UNIBOOKMARK_HOME"]
// TitleOptimizer.swift:228-230
env["UNIBOOKMARK_LLM_API_KEY"]
env["UNIBOOKMARK_LLM_MODEL"]
// AppDelegate.swift:131-132
"local.elidev.UniBookmark.bookmarks"
```

旧项目名 `UniBookmark` 散落各处，容易让新贡献者困惑。

**建议**: 统一改为 `OBELISK_HOME`, `OBELISK_LLM_*`；旧 Spotlight domain 迁移后移除清理代码。

### [M5] 静默丢错误 — 多处

```swift
// UsageStore.swift:174-176 — 使用记录丢失不通知
} catch {
    // Usage data is best-effort; losing a write is not fatal.
}

// main.swift:841-843 — favicon 索引丢失不通知
} catch {
    // Index is a cache; losing it just means we'll re-test more sites.
}

// main.swift:157 — 存储规范化失败静默
try? ObeliskStorageMigrator.normalizeStorage(in: rootDirectory, encrypted: encrypted)
```

虽然是 cache/best-effort 场景，但完全静默导致问题难以调试。特别是在启动阶段（`normalizeActiveStorageRoot`），规范化失败可能导致后续 reads 失败而不显示原因。

**建议**: 使用 `os_log` 记录 .error/.debug 级别的结构化日志。

---

## 四、低危问题 (Low)

### [L1] `Bookmark.encode` 仅序列化核心字段 — `BookmarkStore.swift:47-53`

```swift
public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(title, forKey: .title)
    try c.encode(url, forKey: .url)
    // createdAt, titleOptimized, isHidden, archivedAt 刻意不序列化
}
```

这是设计选择（状态在 `BookmarkStateDatabase` 中独立存储），但 `encode` 与 `CodingKeys` 不一致（CodingKeys 包含了序列化时不写的字段）。若有人调用 `JSONEncoder().encode(bookmark)` 会得到不完整对象而没有任何警告。

**建议**: 在 `encode` 中添加文档注释说明意图，或实现自定义 `encode(to:)` 用不同的临时 CodingKeys。

### [L2] 用户界面无国际化

所有字符串硬编码为中文，无 `NSLocalizedString`。对仅面向中文用户的工具可接受，但限制了扩展性。

### [L3] `README.md` 为空

项目没有任何文档说明用途、构建方式、系统要求。

### [L4] 无 CI/CD 配置

没有 GitHub Actions 或 Xcode Cloud 配置，无法保证每次提交都能通过构建和测试。

### [L5] 异常无结构化日志

仅有一处 `NSLog` 使用（热键注册失败）和零散 AppleScript 错误日志。缺少统一的日志框架。

### [L6] 未使用的 entitlements 文件

`Obelisk.entitlements` 存在但 `project.yml` 未引用它（`CODE_SIGN_ENTITLEMENTS` 未设置），iCloud 权限可能未真正生效。

### [L7] 构建脚本硬编码版本号

`scripts/build-app.sh` 中 `VERSION="1.2.0"` 与 `project.yml` 中 `MARKETING_VERSION: 1.2.0` 重复，存在不一致风险。

---

## 五、建议优先修复列表

| 优先级 | ID | 问题 | 预估工时 |
|--------|-----|------|----------|
| P0 | C1 | API Key 明文存储 | 2h |
| P0 | C2 | 数据一致性无事务保证 | 4h |
| P1 | C3 | 加密开关竞态 | 2h |
| P1 | H5 | LLM prompt injection | 1h |
| P1 | H4 | Favicon 下载无限制 | 1h |
| P2 | H3 | AppleScript 注入 | 3h |
| P2 | H1 | 全局状态同步 | 4h |
| P2 | H2 | flock vs NSFileCoordinator | 3h |
| P3 | M1-M5 | 代码质量改进 | 1-3d |
| P4 | L1-L7 | 文档/日志/CI | 1-2d |

---

## 六、架构总评

**正面**:
- 数据模型设计合理 — 书签/状态/使用记录/配置分层清晰
- favicon 缓存策略细致 — TTL、负缓存、HTML 解析排序
- 文件监控到位 — 支持外部修改自动 reload
- 加密存储完善 — AES-GCM + Keychain 密钥管理方案成熟
- 测试覆盖了核心数据路径 — 26 个 smoke test 覆盖迁移/加密/重复检测/状态清理

**待改进**:
- 两个 1000+ 行的 Swift 文件违反 SRP，维护成本高
- `ObeliskCore` 模块承担过多职责（加密 + 存储 + 迁移 + iCloud），应拆分为子模块
- 全局可变状态通过 `UserDefaults` 广播的变化通知没有完整同步，存在数据竞争隐患
- 没有 protocol/接口抽象层，所有组件直接依赖具体实现，测试难以隔离
