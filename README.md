<div align="center">

<img src="docs/images/icon.png" width="128" alt="LaunchNew">

# LaunchNew

**The classic Launchpad, back on macOS 26 — and free forever.**

[![Release](https://img.shields.io/github/v/release/baka9981/LaunchNew?style=flat-square&color=0A84FF)](https://github.com/baka9981/LaunchNew/releases/latest)
![macOS](https://img.shields.io/badge/macOS-26%2B-111?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)
[![Downloads](https://img.shields.io/github/downloads/baka9981/LaunchNew/total?style=flat-square&color=34C759)](https://github.com/baka9981/LaunchNew/releases)
[![License](https://img.shields.io/badge/license-MIT-8E8E93?style=flat-square)](LICENSE)
[![Website](https://img.shields.io/badge/Website-baka9981.github.io-0A84FF?style=flat-square&logo=safari&logoColor=white)](https://baka9981.github.io/LaunchNew/)

<a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a>

🌐 <a href="https://baka9981.github.io/LaunchNew/"><b>Website</b></a>

<img src="docs/images/whats-new.png" width="49%" alt="What’s New"> <img src="docs/images/guide.png" width="49%" alt="Welcome tour">

</div>

## Why

macOS 26 replaced Launchpad with the Apps window. LaunchNew brings back the full-screen grid you know — pages, folders, drag to arrange, type to search — and adds what Launchpad never had.

## Features

| | |
|---|---|
| 🚀 **Feels like Launchpad** | Full-screen blurred grid, pages, folders, jiggle mode, ⌥Space / F4 / trackpad pinch / hot corner |
| 🔎 **Smarter search** | Pinyin & initials (`wx` → WeChat), aliases, `#tags`, smart folders; math and unit conversion (`128*3`, `5 km in mi`) |
| 📂 **Drop files on icons** | Drop files on an app icon to open them with that app, just like the Dock |
| 🧩 **Custom items** | Websites, files, folders and shell scripts that live on the grid like apps |
| 🎨 **Make it yours** | Change any icon, your own background picture, icon size, animation speed, Dark Mode (follows the Mac, with apps’ own dark icons), Liquid Glass folders and search bar, window or full-screen mode, rows & columns; the grid turns on its side on portrait displays |
| 🗂 **Layouts** | Separate pages for work and play — switch from the menu, a link or Shortcuts |
| 🔔 **Live status** | Dock badges, running indicators, a recent-apps row — ⌘1–⌘9 opens its apps, right-click to pin |
| 🧹 **Clean uninstall** | Removes the app and its leftovers in `~/Library`, straight to the Trash |
| 🕸 **Long-unused apps** | Fade apps not opened in over 3 months, or select them all to move into a folder or hide |
| 🔒 **Private & safe** | Hide apps behind Touch ID, automatic layout backups, optional iCloud sync |
| ⚡️ **Shortcuts & links** | Open folders, search, switch layouts via Shortcuts or `launchnew://` |
| 🔄 **Auto updates** | Signed updates through Sparkle |

## Install

1. Download **LaunchNew-x.y.z.dmg** from the [latest release](https://github.com/baka9981/LaunchNew/releases/latest), open it and drag LaunchNew onto **Applications**.
2. On first launch macOS may say it can’t verify the developer: open **System Settings › Privacy & Security** and click **Open Anyway**.
3. Press **⌥Space** to open. Right-click empty space or press **⌘,** for settings.

Requires macOS 26 or later.

## Build from source

```bash
git clone https://github.com/baka9981/LaunchNew.git
cd LaunchNew
./scripts/run.sh
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for tests, debugging and releases.

## Privacy

LaunchNew has no accounts, no analytics and no network access other than checking for updates. Your layout stays in `~/Library/Application Support/LaunchNew`, and other apps’ data — including the system Launchpad database — is only ever read, never written. The one exception: clicking **Add to Dock** in **Edit…** adds that app to your Dock.

## Free

LaunchNew is completely free. No Pro tier, no subscriptions, no ads.


## License

[MIT](LICENSE)
