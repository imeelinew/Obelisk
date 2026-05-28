# Obelisk 本地签名与 Keychain

Obelisk 的本地加密主密钥与 LLM API Key 都存放在 macOS 钥匙串中，并与应用的 **Bundle ID**、**Team ID**、**keychain-access-groups** 绑定。

## 开发要求

- 使用固定的 `DEVELOPMENT_TEAM` 与 `PRODUCT_BUNDLE_IDENTIFIER`（`com.eli.Obelisk`）进行 Debug / Release 构建。
- **不要**对带用户数据的日常开发使用 ad-hoc 签名；ad-hoc 会在钥匙串中创建另一套条目，导致加密数据无法解密。
- 覆盖安装时请保持同一签名身份；更换 Team 或 Bundle ID 后，旧钥匙串条目可能不可见。

## 加密数据位置

- 明文：`~/Documents/Obelisk/Data/`
- Vault v2（加密）：`~/Documents/Obelisk/Vault/v2/`

## 出问题时

1. 保留 `Vault/`、`EncryptedData/`、`Backup-*` 目录，不要手动删除。
2. 若刚换过签名，可尝试 Time Machine 恢复「登录」钥匙串。
3. 使用应用内明文备份恢复（设置中切换加密时会生成 `Backup-时间戳/`）。

## 验证 entitlements

```bash
codesign -d --entitlements :- /path/to/Obelisk.app
```

应包含 `keychain-access-groups`，且前缀与当前 Team 一致。
