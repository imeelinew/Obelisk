# Obelisk

Obelisk is a native macOS menu bar bookmark tool for quick access, organization, hidden bookmarks, and local archives.

## Build from Source

Requirements:

- macOS 26+
- Xcode with the macOS 26 SDK
- Swift 6

Open the standard Xcode project for daily development:

```bash
open Obelisk.xcodeproj
```

Select the `Obelisk` scheme and `My Mac` in Xcode, then use Product -> Run / Build.

Command-line build:

```bash
xcodebuild -project Obelisk.xcodeproj -scheme Obelisk -configuration Debug build
```

Run the standard tests:

```bash
xcodebuild -project Obelisk.xcodeproj -scheme Obelisk -configuration Debug test
```

Build UI tests separately:

```bash
xcodebuild -project Obelisk.xcodeproj -scheme ObeliskUITests -configuration Debug build
```

Xcode writes the Debug app to the official DerivedData location, usually:

```text
~/Library/Developer/Xcode/DerivedData/Obelisk-*/Build/Products/Debug/Obelisk.app
```

## Local Data

Obelisk stores local bookmark data under:

```text
~/Documents/Obelisk
```

Test targets use temporary directories and do not read or write real bookmark data.
