# 本机 macOS 签名

运行 `./script/install.sh` 构建 Release、签名、安装到 `/Applications/Obelisk.app` 并重启。签名与验证成功后才退出旧实例；安装使用 mac-sign 的暂存、校验与替换流程。

依赖 Xcode 命令行工具、Python 3、已安装的 ai-mac-sign 插件，以及钥匙串中的有效 Apple Development 身份。脚本自动定位已安装插件；也可通过 `MAC_SIGN_SCRIPT` 指定其 `mac_sign.py` 路径。

`.ai-sign.json` 提供只构建的命令、唯一 Bundle ID 和安装位置。`./scripts/sign.sh --build` 可按配置重建并签名安装，但不管理运行中的进程；日常安装和重启使用 `install.sh`。只签构建产物可运行 `./scripts/sign.sh --output "$(python3 scripts/xcode-path.py Release)"`。

Release 开启 Hardened Runtime，并关闭调试 entitlement 注入；Debug 保留调试能力。所有嵌套代码从内到外签名，`--deep` 只用于验证。构建与 Xcode GUI 共用 `~/Library/Developer/Xcode/DerivedData` 下的项目目录，实际路径由 `scripts/xcode-path.py` 读取 Xcode 构建设置。验证报告默认在该项目目录的 `local-signing.json`，可通过 `MAC_SIGN_REPORT` 指定其他位置。

现有证书身份与 Bundle ID 会保持稳定；跨重建身份要求验证和隐私权限保留是两个不同结果，应分别确认。本机开发签名不代表已公证。
