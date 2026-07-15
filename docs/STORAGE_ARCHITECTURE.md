# Obelisk 1.9 存储与同步架构

本文定义 Obelisk 1.9 的唯一持久化与同步契约。SQLite 是应用始终使用的本地数据库；开启云同步后，PostgreSQL 同时成为云端事实源，PowerSync 负责两者收敛，Obelisk API 负责身份认证与所有云端写入。生产代码不识别旧 Vault 格式，也不包含旧格式迁移器。

## 设计原则

- 离线优先：本地增删改查不依赖网络，重连后自动同步。
- 一个领域模型：macOS、iOS、SQLite、API 与 PostgreSQL 使用相同实体和字段语义。
- 一个本地数据库：书签、分组、使用事件、最近浏览和浏览器选择不再分散到独立文件或存储器。
- 确定性收敛：普通字段按字段合并；并发结果不依赖请求到达顺序。
- 幂等上传：同一个本地操作无论重试多少次，服务端只应用一次。
- 最小钥匙串职责：钥匙串只保存登录会话，不再保存数据库加密密钥。
- 同步可选：关闭云同步时不读取登录会话、不连接服务器，所有功能继续使用同一个本地数据库。

## 组件与数据流

```text
macOS / iOS UI
      │
      ▼
ObeliskCore + ObeliskData
      │ local transaction
      ▼
PowerSync SQLite ── queued mutations ──▶ Obelisk API ──▶ PostgreSQL
      ▲                                      │
      └──────── PowerSync sync streams ◀─────┘
```

客户端永远先提交本地 SQLite 事务。关闭云同步时，修改保留在本机队列中；重新开启并完成认证后，PowerSync 自动上传积累的修改并拉取远端更新。连接可用时，客户端将事务作为一个 mutation batch 发送给 Obelisk API。API 在一个 PostgreSQL 事务内完成鉴权、幂等检查、字段合并与约束校验。提交后的 PostgreSQL 变更再由 PowerSync 同步到该账户的所有设备。

本地同步表不保存 `owner_id`。PowerSync stream 已按 JWT 中的账户 ID 隔离数据，本地数据库在首次登录时再通过 local-only `sync_state` 绑定唯一账户；同一个数据库不能切换到另一个账户。

## 数据模型

### `collections`

保存分组名称、顺序键、菜单显示状态、字段版本和软删除时间。

### `bookmarks`

保存分组关系、标题、URL、标题优化状态、隐藏状态、归档时间、置顶状态、原始标题、顺序键、字段版本和软删除时间。

### `usage_events`

每次打开书签产生一个不可变事件。频率和最近使用时间由事件聚合得到；不同设备的事件只做集合并集，不执行读改写计数器，因此离线并发不会丢失点击。

### `browser_history_events`

macOS 从用户选择的浏览器只读采集最近浏览记录，并以不可变事件写入本地数据库。事件保存来源设备、浏览器、浏览器配置、标题、URL 和访问时间，通过 PowerSync 同步到该账户的所有设备。各端只保留并展示最近 30 天的数据，按访问时间排序并按 URL 去重。它与书签 `usage_events` 相互独立。

### `browser_history_settings`

保存最近浏览页面当前启用的浏览器。它使用与书签和分组相同的 HLC 字段版本合并规则，通过 PowerSync 在设备间收敛。macOS 按这份设置采集和筛选浏览器历史，iOS 按同一份设置筛选同步下来的记录；任一端修改选择后，另一端会自动得到相同选择。

### 身份与运维表

`accounts`、`devices`、`sessions`、`applied_mutations` 和 `schema_version` 只存在于 PostgreSQL，不通过 PowerSync 下发。

## 冲突规则

可编辑字段各自携带 Hybrid Logical Clock（HLC）：

```text
wall-clock milliseconds + logical counter + device UUID
```

客户端写入前先观察当前记录的最大远端版本，再生成本次版本。服务端逐字段比较 HLC，只接受严格更新的字段；相同毫秒和计数器由 device UUID 提供稳定的最终顺序。这样两台设备同时修改不同字段时两项修改都会保留，同时修改同一字段时所有副本会得到相同胜者。

删除使用带版本的 `deleted_at` tombstone，不执行物理删除。隐藏、归档或删除状态优先于置顶状态；服务端统一强制该不变量。

## 幂等与事务

每次本地写入生成 mutation UUID，并由 PowerSync metadata 附在 CRUD 项上。服务端以 `(owner_id, device_id, mutation_id)` 为主键登记已应用操作。一个 batch 的登记与领域写入位于同一 PostgreSQL 事务中：失败时全部回滚，网络重试不会重复产生效果。

## 身份认证与隔离

- 密码：Argon2id 哈希后存储。
- API access token：RS256 JWT，短时有效，audience 为 `obelisk-api`。
- PowerSync token：独立 RS256 JWT，audience 为 `powersync`。
- Refresh token：随机生成，数据库只保存 SHA-256 摘要，每次刷新都轮换。
- 同步隔离：PowerSync stream 固定使用 `owner_id = auth.user_id()`。
- 写入隔离：服务端忽略客户端声明的 owner/device，以 JWT claims 为准，并由复合外键再次约束。
- 账户边界：没有公开注册 API。当前唯一账户只能通过服务器上的 `obelisk-api create-account` 管理命令创建。

生产部署必须在 API、PowerSync 和客户端之间启用 TLS。JWT 私钥、数据库密码和 PowerSync 管理 token 不得进入仓库。

## 本地文件与钥匙串

```text
~/Library/Application Support/com.eli.Obelisk/
└── Sync/
    ├── obelisk-sync.sqlite
    ├── obelisk-sync.sqlite-wal
    └── obelisk-sync.sqlite-shm

~/Library/Caches/com.eli.Obelisk/
└── Favicons/
```

SQLite 是本地工作数据库，不做应用层 AES 加密。开启云同步后，它也可由云端数据重建；未开启云同步时，它就是该设备上唯一的数据副本。磁盘保护依赖 macOS/iOS 的系统数据保护、用户登录和设备加密。隐藏书签的设备所有者认证属于界面访问控制，并不表示对应云端行经过端到端加密。

开启云同步时，每次本地增删改查都必须立即进入上传流程，其他在线设备必须自动收敛。应用回到前台或网络恢复时必须自动恢复或重建同步连接，不能依赖用户执行手动同步操作。

SQLite 文件只能属于创建它的设备，不得在设备之间整库复制。数据库内包含 PowerSync 客户端身份、checkpoint 和待上传队列；新设备必须创建空数据库，再通过云同步下载领域数据。

钥匙串只保存 `ObeliskAuthSession`，关闭云同步启动应用时不会读取该项目：

- service：`com.eli.Obelisk.sync.session`
- account：`primary`
- accessibility：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

非敏感的设备 UUID 保存在 UserDefaults。LLM 远程 API Key 使用独立的钥匙串项目。

## 签名契约

macOS 客户端的签名身份保持：

- Bundle ID：`com.eli.Obelisk`
- Team ID：`5Q5QT76MJU`
- Keychain access group：`5Q5QT76MJU.com.eli.Obelisk`

发布前必须检查最终 `.app` 的 Identifier、TeamIdentifier、签名 Authority 与 entitlements。任何改变 Bundle ID、Team ID 或钥匙串组的变更都必须先提供显式会话迁移方案。

## 部署边界

仓库中的 `Server/` 是完整的自托管单元：PostgreSQL 18、PowerSync Service、Obelisk API 与唯一数据库 schema。开发环境可由 Docker Compose 启动；正式环境需要持久卷、数据库备份、TLS 终止、密钥轮换、日志与健康检查。

发布版 `Info.plist` 必须提供 `ObeliskAPIURL` 和 `ObeliskPowerSyncURL` 两个 HTTPS 地址。开发构建可用 `OBELISK_API_URL` 与 `OBELISK_POWERSYNC_URL` 环境变量覆盖它们。服务端 `OBELISK_TOKEN_ISSUER` 必须等于公开 API 地址，仓库不提供任何虚构的生产默认值。
