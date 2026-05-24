# Obelisk 本地签名与 Keychain 开发说明

## 目标

- **稳定签名**：同一 Apple Development 证书 + Team + Bundle ID，避免每次编译触发 Keychain 授权或无法访问旧项。
- **防覆盖**：应用**不会**在已有加密数据时用新密钥覆盖钥匙串中的加密主密钥。

## 推荐构建方式

| 方式 | 说明 |
|------|------|
| **Xcode → Product → Run** | 日常开发唯一推荐路径 |
| `scripts/verify-dev-signing.sh` | 发布或改 Team 后必须通过 |
| `scripts/build-app.sh` | 打 `.app` 安装包；需本机已有对应 Team 的证书 |
| `scripts/dev-run.sh` | `swift build` + 按 Team 签名；仅在与 verify 脚本同 Team 时使用 |
| 裸 `swift run` / 未签名 `.build/.../Obelisk` | **禁止**（adhoc，Keychain 会分裂） |

## 严格验证（必须通过才算验收）

在仓库根目录：

```bash
# 1. 先 Xcode 编一次 Debug
xcodebuild -scheme Obelisk -configuration Debug build -quiet

# 2. 验证 Team / Bundle / codesign（可传入 .app 路径）
./scripts/verify-dev-signing.sh

# 3. 可选：两次 clean build 后 designated requirement 必须一致（较慢）
COMPARE_DR=1 ./scripts/verify-dev-signing.sh
```

**通过标准**（脚本 exit 0）：

- `project.yml` 与 `xcodebuild` 的 `DEVELOPMENT_TEAM` 均为 `5Q5QT76MJU`（Fred Personal Team）
- `PRODUCT_BUNDLE_IDENTIFIER = local.elidev.Obelisk`
- 非 adhoc 签名；`TeamIdentifier=5Q5QT76MJU`
- `COMPARE_DR=1` 时两次 clean build 的 designated requirement 字符串相同

## Team 与证书

- **真源配置**：[`project.yml`](../project.yml) 中的 `DEVELOPMENT_TEAM`
- 修改 Team 后执行 `xcodegen generate` 并提交 `Obelisk.xcodeproj`
- 脚本默认 `DEVELOPMENT_TEAM_ID=5Q5QT76MJU`；**找不到该 Team 证书会直接失败**，不会 fallback 到其他 Apple Development 证书

## Entitlements

[`Obelisk.entitlements`](../Obelisk.entitlements) 保持为空（无 `keychain-access-groups`），避免钥匙串再分区。若将来添加 access group，必须先做只读复制、双份共存，**禁止**删除 legacy 加密主密钥项。

## 本地数据加密

- 开启 `encryptLocalJSONData` 前请备份 `~/Documents/Obelisk/EncryptedData/`
- 切换 Team/签名后若提示找不到加密密钥，**应用不会自动新建密钥覆盖**（会抛出 `encryptionKeyMissing` / `encryptionKeyWouldOverwrite`）
- 密钥曾丢失时：关闭加密、重建书签库，或从备份恢复钥匙串

## Keychain 行为摘要

| 项 | Service | 说明 |
|----|---------|------|
| 加密主密钥 | `local.elidev.Obelisk.encryption` | 有 `.bin` 且无密钥时不创建；拒绝无法解密样本的覆盖写入 |
| 远程 LLM API Key | `local.elidev.Obelisk.llm-apikey` · `remote` | 仅存 Keychain |
| 本地 LM Studio Key | `llm.json` | 已从 Keychain 迁出 |

## 自动化测试

```bash
swift build --product ObeliskSmokeTests
.build/debug/ObeliskSmokeTests
```

覆盖：有密文无密钥不创建、拒绝异密钥覆盖、迁移不碰 encryption service。
