# Obelisk Agent Rules

本文件是给后续 agent 的硬规则。Obelisk 是一个本地 macOS 菜单栏 app，书签数据和本地加密密钥绑定到 macOS Keychain、Bundle ID、Team ID 和签名身份。普通功能可以迭代，但身份、签名、Keychain、数据迁移这几块不能随意碰。

## 最高红线

没有用户明确允许，不要修改这些文件或行为：

- `project.yml` 里的 `DEVELOPMENT_TEAM`、`PRODUCT_BUNDLE_IDENTIFIER`、`CODE_SIGN_ENTITLEMENTS`
- `Obelisk.entitlements`
- `scripts/build-app.sh`
- `scripts/verify-dev-signing.sh`
- `scripts/codesign-identity.sh`
- `scripts/sign-local-binary.sh`
- `scripts/dev-run.sh`
- `docs/local-signing.md`
- `Sources/ObeliskCore/SecureJSONFileCodec.swift` 里的 Keychain、加密主密钥、AES-GCM envelope 逻辑
- `ObeliskStorageMigrator`、`ObeliskStorageTransition`、`ObeliskPlaintextDataBackup` 相关迁移/备份逻辑

如果任务看起来需要触碰以上内容，先停下，向用户说明原因和风险，拿到明确批准后再改。

## 签名和构建规则

- 日常开发入口是 Xcode `Product -> Run` / `Product -> Build`。
- 生成安装包只使用 `scripts/build-app.sh`。
- 不要用裸 `swift run` 跑真实用户数据。
- 不要引入 ad-hoc signing。
- 不要 fallback 到任意 `Apple Development` 证书。
- 固定 Bundle ID 是 `local.elidev.Obelisk`。
- 固定 Team ID 是 `5Q5QT76MJU`。
- 不要新增 `keychain-access-groups`，除非用户明确要求并接受迁移风险。

## 数据和 Keychain 规则

- 不要删除、重建或直接编辑用户数据目录：`/Users/eli/Documents/Obelisk`。
- 不要删除或覆盖 Obelisk 的 Keychain 项，尤其是 `local.elidev.Obelisk.encryption` / `default-v1`。
- 不要为了“修复无法解密”自动创建新加密主密钥。
- 有 `EncryptedData` 或 legacy `PrivateData` 密文时，迁移前必须先确认当前 Keychain key 能解密样本文件。
- 开启或关闭 `encryptLocalJSONData` 前必须先创建可读备份；备份失败则中止迁移。
- 存储整理逻辑不能在坏签名、坏 Keychain、无法解密状态下继续搬移或删除旧路径。

## 普通功能改动

可以正常修改 UI、菜单、书签列表、标题优化、通知、快捷键、视觉样式等功能代码。保持改动聚焦，不要顺手重构签名、构建、Keychain 或数据迁移层。

如果改动涉及书签保存、隐藏书签、归档、分组、usage、favicon 缓存或 LLM 配置存储，要额外确认不会破坏：

- 明文/密文两种存储模式
- legacy 路径迁移
- 空书签库不会擦掉 sidecar 状态
- 备份失败不会继续迁移

## 验证命令

普通代码改动至少跑：

```bash
swift run ObeliskSmokeTests
swift build --product Obelisk
git diff --check
```

触碰签名、构建、entitlements、Bundle ID、Team ID、安装包或本地加密迁移时，必须额外跑：

```bash
xcodebuild -scheme Obelisk -configuration Debug build -quiet
./scripts/verify-dev-signing.sh
scripts/build-app.sh
./scripts/verify-dev-signing.sh .build/dist/Obelisk.app
```

签名验收必须确认：

- `Identifier=local.elidev.Obelisk`
- `TeamIdentifier=5Q5QT76MJU`
- 不是 `Signature=adhoc`

## 工作方式

- 先读真实文件再判断，不要凭记忆改。
- 不要 revert 用户或其他 agent 的未提交改动。
- 不要覆盖安装 `/Applications/Obelisk.app`，除非用户明确要求。
- 不要修改本机 Keychain、用户数据目录或系统安装状态，除非用户明确要求。
- 如果出现“数据丢失、无法解密、Keychain prompt、签名变化、Bundle ID 变化”相关症状，先诊断根因，不要试探式改代码。
