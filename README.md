# UniBookmark

## 项目结构

```text
UniBookmark/
├── Package.swift
├── README.md
├── scripts/
│   └── build-app.sh
└── Sources/
    ├── UniBookmarkCore/
    │   └── BookmarkStore.swift
    └── UniBookmarkMenu/
        └── main.swift
```

## 功能模块

### UniBookmarkCore

`Sources/UniBookmarkCore/BookmarkStore.swift`

- 定义书签数据模型 `Bookmark`。
- 定义本地 JSON 数据库模型 `BookmarkDatabase`。
- 定义本地存储读写类 `BookmarkStore`。
- 默认数据目录为 `~/Documents/UniBookmark`。
- 支持通过环境变量 `UNIBOOKMARK_HOME` 指定数据目录。
- 数据文件名为 `bookmarks.json`。
- 书签字段为 `id`、`title`、`url`。
- 添加书签时检查 URL 是否包含 scheme。
- 添加书签时按规范化 URL 去重。
- 读取书签时按标题排序。
- 数据文件不存在时创建默认数据。

### UniBookmarkMenu

`Sources/UniBookmarkMenu/main.swift`

- macOS 菜单栏应用。
- 使用 `NSStatusBar.system.statusItem` 创建菜单栏图标。
- 菜单栏图标使用 SF Symbols 的 `bookmark.fill`。
- 应用设置为 accessory activation policy。
- 菜单内容包含标题 `书签`、分割线、书签列表、分割线、`退出`。
- 每条书签使用 `NSMenuItem` 显示。
- 点击书签时通过 `NSWorkspace.shared.open` 使用默认浏览器打开 URL。
- 书签标题使用 macOS 菜单字体按像素宽度截断。
- 书签 tooltip 显示完整标题和 URL。
- favicon 缓存在数据目录下的 `favicons/`。
- 菜单项优先读取本地 favicon 缓存。
- 缓存不存在时后台下载 favicon。
- favicon 下载完成后刷新菜单。
- 使用文件系统事件监听 `bookmarks.json` 和数据目录。
- JSON 添加、修改、删除或原子替换后触发菜单刷新。

### build-app.sh

`scripts/build-app.sh`

- 使用 Swift Package Manager 构建 release 产物。
- 构建 `UniBookmarkMenu`。
- 生成 `.build/dist/UniBookmark.app`。
- `.app` 的可执行文件为 `Contents/MacOS/UniBookmark`。
- `Info.plist` 设置 `LSUIElement` 为 `true`。

## 实现方法

### 数据存储

默认数据路径：

```text
~/Documents/UniBookmark/bookmarks.json
```

自定义数据路径：

```sh
UNIBOOKMARK_HOME=/path/to/bookmark-directory
```

JSON 结构：

```json
{
  "bookmarks": [
    {
      "id": "UUID",
      "title": "Title",
      "url": "https://example.com"
    }
  ],
  "version": 1
}
```

### 菜单刷新

`BookmarkFileWatcher` 使用 `DispatchSource.makeFileSystemObjectSource` 监听：

- `bookmarks.json`
- `bookmarks.json` 所在目录

监听事件包括：

- `write`
- `delete`
- `rename`
- `revoke`

事件触发后通过主线程防抖调用 `rebuildMenu()`。

### favicon

`FaviconLoader` 的缓存目录：

```text
~/Documents/UniBookmark/favicons/
```

缓存文件名根据 URL host 和 port 生成。

下载顺序：

1. `<origin>/favicon.ico`
2. `<origin>/favicon.png`
3. `<origin>/apple-touch-icon.png`
4. 解析页面 HTML 中的 icon link

下载到的图像转换为 PNG 后写入缓存目录。

### 构建和运行

构建：

```sh
swift build
```

运行菜单栏应用：

```sh
swift run UniBookmarkMenu
```

构建 `.app`：

```sh
scripts/build-app.sh
```

启动 `.app`：

```sh
open .build/UniBookmark.app
```

