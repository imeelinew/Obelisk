<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Obelisk">
</p>

<h1 align="center">Obelisk</h1>

<p align="center">
  A native bookmark shelf that lives in your macOS menu bar.<br>
  Fast access, shortcut-based adding, local storage, hidden bookmarks, AI optimization, and a polished app window.
</p>


<p align="center">
  <a href="https://github.com/imeelinew/Obelisk/releases">Download</a> ·
  <a href="#install">Install</a> ·
  <a href="#build-from-source">Build from source</a>
</p>

<p align="center">
  <a href="README.en.md">English</a>
  <a href="README.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Obelisk/releases/latest"><img src="https://img.shields.io/github/v/release/imeelinew/Obelisk" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

---

<p align="center">
  <img alt="Obelisk bookmark manager window" src=".github/assets/app.png" width="800">
</p>

## About

Obelisk is an elegant, native macOS bookmark manager for people who switch browsers often, want bookmarks close at hand, and do not want to keep everything inside the browser.

It keeps a lightweight native menu in the menu bar for quick access, and opens a full app window when you need to organize. Bookmarks are stored locally on disk, protected with AES encryption. Your key is stored safely in iCloud Keychain and can only be unlocked with your password or fingerprint.

## Why Obelisk

Browser bookmarks are usually tied to one browser, buried in sidebars or nested menus, and often mixed with sync accounts. Obelisk takes bookmarks out of the browser and makes them feel more like a small system utility.

- **Menu bar first**: open pinned, recently added, and full bookmark lists without switching windows.
- **Native settings window**: search, organize, hide, and archive bookmarks in a macOS-style window.
- **Hidden bookmarks**: protect sensitive bookmarks with device-owner authentication.
- **Local encrypted storage**: bookmark data lives in `Obelisk.obelisk` under your local `Application Support` folder.
- **AI optimization**: Obelisk supports BYOK for automatic title optimization and auto-grouping. I call this Intelligence. As your collection grows over time, the automatic cleanup stays convenient and easy to scan.

## Menu Bar

<p align="center">
  <img alt="Obelisk menu bar dropdown" src=".github/assets/menu.png" width="480">
</p>

The menu bar supports fully custom ordering, and each group supports multiple sort modes, including the most useful one: sort by usage frequency.

## Quick Add

<p align="center">
  <img alt="Obelisk bookmark added notification" src=".github/assets/notification.png" width="600">
</p>
<p align="center">  <img alt="Obelisk bookmark optimization notification" src=".github/assets/optimize.png" width="600"></p>

On the current tab, press `Option + B`. Obelisk reads the frontmost browser's URL and title, then shows a lightweight popover to confirm the bookmark was saved. Shortcuts are customizable. If you trigger one by mistake, press `Option + Z` within 5 seconds to undo. If Intelligence is enabled and configured, Obelisk can optimize page titles (even translate them) and place the bookmark into a suitable group automatically.

## More Features

- Menu bar bookmark launcher with favicons
- Full bookmark management window
- Hidden bookmarks protected by local authentication, with support for opening them in private windows
- Filter URLs containing specific keywords so they can only be added as hidden bookmarks, helping prevent privacy leaks
- Automatically archive bookmarks you have not used for a while
- Search, edit, delete, copy URL, refresh favicons, and other expected bookmark actions
- Optional frosted-glass transparency for a lighter window

## Install

Download the latest release from the [Releases page](https://github.com/imeelinew/Obelisk/releases), then move `Obelisk.app` to `/Applications`.
