# Obelisk 存储架构

本文定义 Obelisk v3 的持久化、安全与恢复契约。实现以本文为准；任何会改变数据库格式、钥匙串身份或恢复流程的提交，都必须同步更新本文和相应测试。

## 设计目标

- 本地数据始终加密，不提供关闭加密的运行时开关。
- 正常启动不弹出传统文件钥匙串授权窗口。
- 单条书签更新只重写对应记录，不重写整个数据集。
- 钥匙串项目丢失时拒绝覆盖现有数据，并允许通过独立恢复密钥恢复。
- 备份是单一、可搬运、仍然加密的 SQLite 文件。
- 旧格式迁移只执行一次；正式运行时代码不包含旧格式探测或解码器。

## 威胁模型

v3 保护静态数据库、SQLite journal 和加密备份在被单独复制时不泄露书签内容，也能检测密文或记录身份被篡改。它不试图防御已解锁用户会话中的恶意进程、被注入的 Obelisk 进程、屏幕/剪贴板采集，或拥有恢复密钥的攻击者。

“隐藏书签”的 Touch ID/密码门禁属于界面访问控制，不替代静态加密；所有书签记录在磁盘上都使用同一强度的认证加密。

## 文件布局

```text
~/Library/Application Support/com.eli.Obelisk/
└── Data/
    ├── store.sqlite
    ├── store.sqlite-wal
    └── store.sqlite-shm

~/Library/Caches/com.eli.Obelisk/
└── Favicons/
```

数据目录权限为 `0700`，数据库及边车文件为 `0600`。Favicon 是可重新下载的非权威缓存，不进入加密数据库。

## 密钥层级

1. 每个 vault 生成一个随机 256-bit 数据加密密钥（DEK）。
2. DEK 作为 generic-password 项目存入 macOS Data Protection Keychain：
   - service：`com.eli.Obelisk.vault.v3`
   - account：`primary`
   - access group：`5Q5QT76MJU.com.eli.Obelisk`
   - accessibility：`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
   - 所有查询都设置 `kSecUseDataProtectionKeychain = true`，不启用 iCloud 同步。
3. 建库时另生成随机 256-bit 恢复密钥。恢复密钥使用 AES-256-GCM 包装 DEK，包装结果写入数据库 metadata；恢复密钥本身只写入用户指定的独立文件，默认是 `~/Documents/Obelisk Recovery Key.txt`，权限为 `0600`。

应用绝不从数据库重新生成 DEK。数据库存在而钥匙串项目缺失时，加载必须失败；只有恢复密钥成功解开 DEK，并且该 DEK 能完整解密当前数据库后，才允许写回钥匙串。

## 数据库格式

SQLite `metadata` 表仅保存格式版本、payload schema 版本、随机 vault ID 和被恢复密钥包装的 DEK。`records` 表按实体保存密文：

- 每条书签一条 `bookmark` 记录；
- 分组集合一条 `groups` 记录；
- LLM profiles 一条 `llmProfiles` 记录。

每条记录使用 AES-256-GCM 和独立随机 nonce。AAD 固定绑定：

```text
vault ID | record kind | record ID | schema version
```

因此密文不能在记录之间替换，也不能移入另一个 vault。记录 kind、ID、更新时间和总数不是秘密；标题、URL、隐藏状态、分组关系、使用记录和模型配置均在密文内。

## 一致性与故障处理

- SQLite 使用 WAL、`synchronous=FULL`、事务写入和 busy timeout。
- 同一数据目录的进程内访问经串行 coordinator 协调。
- 保存操作比较前后 payload，只删除或重写发生变化的实体记录。
- 新 vault 初始化必须同时完成 schema、初始记录、恢复文件和钥匙串写入；任一步失败都删除新数据库和新恢复文件，不留下半初始化状态。
- 每次恢复或迁移都执行 SQLite `quick_check` 和全记录认证解密。

## 备份与恢复

“创建加密数据库备份”使用 SQLite Online Backup API 获取一致快照，并切换为 DELETE journal，最终产物只有一个 `.sqlite` 文件。备份不包含恢复密钥；两者应分开保存。

“使用恢复密钥”只恢复当前数据库的 DEK，不导入旧格式、不创建新数据库，也不覆盖验证失败的数据。Obelisk 不提供明文数据导出功能。

## 签名契约

Data Protection Keychain 的访问能力来自宿主应用签名，以下三项必须稳定：

- Bundle ID：`com.eli.Obelisk`
- Team ID：`5Q5QT76MJU`
- Keychain access group：`5Q5QT76MJU.com.eli.Obelisk`

构建或发布流程必须检查最终 `.app` 的 `Identifier`、`TeamIdentifier`、签名 Authority 和 entitlements。测试宿主在应用入口即切换到临时目录和内存密钥存储，禁止触碰真实数据库或真实钥匙串。

## 参考

- [Apple TN3137: On Mac keychain APIs and implementations](https://developer.apple.com/documentation/Technotes/tn3137-on-mac-keychains)
- [Apple: kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- [Apple: Keychain Access Groups Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/keychain-access-groups)
- [Apple: kSecAttrAccessibleWhenUnlockedThisDeviceOnly](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)
