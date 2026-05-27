# Obelisk

Obelisk 是一个住在 macOS 菜单栏里的原生书签工具，用于快速打开、整理、隐藏和归档本地书签。

## 从源码构建

要求：

- macOS 26+
- 带 macOS 26 SDK 的 Xcode
- Swift 6

日常开发直接打开标准 Xcode 项目：

```bash
open Obelisk.xcodeproj
```

在 Xcode 中选择 `Obelisk` scheme 和 `My Mac`，然后使用 Product -> Run / Build。

命令行构建：

```bash
xcodebuild -project Obelisk.xcodeproj -scheme Obelisk -configuration Debug build
```

运行标准测试：

```bash
xcodebuild -project Obelisk.xcodeproj -scheme Obelisk -configuration Debug test
```

单独构建 UI tests：

```bash
xcodebuild -project Obelisk.xcodeproj -scheme ObeliskUITests -configuration Debug build
```

Xcode 的 Debug app 产物位于官方 DerivedData 路径，通常形如：

```text
~/Library/Developer/Xcode/DerivedData/Obelisk-*/Build/Products/Debug/Obelisk.app
```

## 本地数据

Obelisk 默认把书签数据保存在：

```text
~/Documents/Obelisk
```

测试 target 会使用临时目录隔离，不会读写真实书签数据。
