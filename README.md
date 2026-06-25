<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Obelisk">
</p>

<h1 align="center">Obelisk</h1>

<p align="center">
  一个住在 macOS 菜单栏里的原生书签架。<br>
  快速打开、快捷键添加、本地存储、隐藏书签、AI 优化，以及一个漂亮的应用窗口。
</p>


<p align="center">
  <a href="https://github.com/imeelinew/Obelisk/releases">下载</a> ·
  <a href="#安装">安装</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="README.md">简体中文</a>
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Obelisk/releases/latest"><img src="https://img.shields.io/github/v/release/imeelinew/Obelisk" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

---

<p align="center">
  <img alt="Obelisk 书签管理窗口" src=".github/assets/app.png" width="800">
</p>

## 简介

Obelisk 是一个优雅而原生的 macOS 书签管理器，适合那些频繁切换浏览器、并且希望书签随手可用、但又不想把一切都塞回浏览器的人。

它在菜单栏里保留一个很轻的原生菜单，可以快速打开书签；需要整理的时候，再进入完整的应用窗口。书签默认保存在本地磁盘，并且使用 AES 加密确保你的隐私安全，你的密钥会安全无虞地存储在 iCloud Keychain 中，只有你的密码或者指纹才能解密。

## 为什么开发 Obelisk

浏览器书签通常和某一个浏览器绑定，藏在侧栏或层层菜单里，也常常和同步账号混在一起。Obelisk 把书签从浏览器里拿出来，让它更像一个小型系统工具。

- **菜单栏优先**：不用切换窗口，就能打开置顶、最近添加和完整书签列表。
- **原生设置窗口**：用 macOS 风格的窗口搜索、整理、隐藏、归档书签。
- **隐藏书签**：通过设备所有者认证保护敏感书签。
- **本地加密存储**：书签数据保存在本机 `Application Support` 目录下的 `Obelisk.obelisk`。
- **AI 优化**：Obelisk 支持你 BYOK 来自动给书签进行标题优化和自动分组，我将其命名为 Intelligence，当你的书签数量随着时间不断增长时，你便会感到自动优化功能的方便和清晰。

## 菜单栏

<p align="center">
  <img alt="Obelisk 菜单栏下拉菜单" src=".github/assets/menu.png" width="480">
</p>

菜单栏支持你完全自定义排序，并且每个分组都支持多种排序方式、包括最常用的「按使用频率排序」

## 快速添加

<p align="center">
  <img alt="Obelisk 添加书签提示" src=".github/assets/notification.png" width="600">
</p>
<p align="center">  <img alt="Obelisk 添加书签提示" src=".github/assets/optimize.png" width="600"></p>

你只需要在当前标签页面轻轻地按下 `Option + B`，Obelisk 会自动读取最前方浏览器的 URL 和标题，并用一个轻轻的 Popover 提示告诉你书签已经保存。你可以自定义快捷键，如果你误触了快捷键，5s 内可以使用 `Option + Z` 来撤回操作。如果你还开启并且配置了 Intelligence 功能，Obelisk 会自动优化网页的名字（甚至翻译）并且自动选择合适的分组。

## 其他功能

- 带 favicon 的菜单栏书签启动器
- 完整的书签管理窗口
- 受本地认证保护的隐藏书签，还支持使用无痕窗口打开隐藏书签
- 排序含有特定关键词的网址，使其只能添加到隐藏书签，防止隐私泄漏
- 自动归档你一段时间没有使用的书签
- 搜索、编辑、删除、复制 URL、刷新 favicon 等理所当然的操作功能
- 可选的毛玻璃透明效果，让应用更透亮

## 安装

从 [Releases 页面](https://github.com/imeelinew/Obelisk/releases)下载最新版，把 `Obelisk.app` 放到 `/Applications`。
