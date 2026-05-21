<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Obelisk">
</p>

<h1 align="center">Obelisk</h1>

<p align="center">
  一个住在 macOS 菜单栏里的原生书签架。<br>
  快速打开、本地存储、隐藏书签，以及一个安静的设置窗口。
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Obelisk/releases">下载</a> ·
  <a href="#安装">安装</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="README.md">English</a>
  <a href="README.zh.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Obelisk/releases/latest"><img src="https://img.shields.io/github/v/release/imeelinew/Obelisk" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

---

<p align="center">
  <img alt="Obelisk 书签管理窗口" src=".github/assets/app.png" width="800">
</p>

## 关于

Obelisk 是一个菜单栏书签管理器，适合那些希望书签随手可用、但又不想把一切都塞回浏览器的人。

它在 macOS 菜单栏里保留一个很轻的原生菜单，可以快速打开书签；需要整理的时候，再进入完整的设置窗口。书签默认保存在本地磁盘，也可以给隐私数据开启本地加密。

## 为什么做 Obelisk

浏览器书签通常和某一个浏览器绑定，藏在侧栏或层层菜单里，也常常和同步账号混在一起。Obelisk 把书签从浏览器里拿出来，让它更像一个小型系统工具。

- **菜单栏优先**：不用切换窗口，就能打开常用、最近添加和完整书签列表。
- **原生设置窗口**：用 macOS 风格的窗口搜索、整理、隐藏、归档书签。
- **隐藏书签**：通过设备所有者认证保护敏感书签。
- **本地存储**：书签数据保存在本机 Documents 目录下。
- **可选清理**：需要时可以用 AI 优化书签标题。

## 菜单栏

<p align="center">
  <img alt="Obelisk 菜单栏下拉菜单" src=".github/assets/menu.png" width="480">
</p>

菜单会按使用频率和添加时间组织书签，完整列表放在下一级。

## 快速添加

<p align="center">
  <img alt="Obelisk 添加书签提示" src=".github/assets/notification.png" width="600">
</p>

用全局添加书签快捷键保存当前浏览器标签页。Obelisk 会读取最前方浏览器的 URL 和标题，并用一个轻量提示告诉你书签已经保存。

## 功能

- 带 favicon 的菜单栏书签启动器
- 完整的书签管理窗口
- 受本地认证保护的隐藏书签
- 旧书签和手动归档书签的归档视图
- 搜索、编辑、删除、复制 URL、刷新 favicon
- 可配置的菜单数量和窗口外观
- 可选静默添加流程
- 可选本地 JSON 加密
- 可选 AI 标题优化

## 安装

从 [Releases 页面](https://github.com/imeelinew/Obelisk/releases)下载最新版，把 `Obelisk.app` 放到 `/Applications`。

Obelisk 是菜单栏应用。启动后，在 macOS 菜单栏里找 Obelisk 图标即可。

## 从源码构建

要求：

- macOS 26+
- 带 macOS 26 SDK 的 Xcode
- Swift 6
- 如果要从 `project.yml` 重新生成 Xcode 工程，需要 XcodeGen

构建本地 app：

```bash
scripts/build-app.sh
```

构建结果会输出到：

```text
.build/dist/Obelisk.app
```

本地快速检查：

```bash
swift build
swift run ObeliskSmokeTests
```

## 存储

默认情况下，Obelisk 会把本地书签数据保存在：

```text
~/Documents/Obelisk
```

书签数据、使用记录、书签状态和 favicon 会分开保存。这样菜单可以保持轻快，设置窗口则负责更完整的整理工作。
