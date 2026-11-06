# 开发说明

Swift 6 + SwiftUI + AppKit，SwiftPM 构建，需要 macOS 26 和 Xcode 26。

## 构建与测试

```bash
./scripts/run.sh            # 构建 build/LaunchUS.app 并启动
./scripts/build.sh          # 只构建（release 构建会生成快捷指令元数据）
swift test --parallel       # 单元测试
./scripts/l10n-missing.sh   # 检查 en / ja / zh-Hant 是否缺翻译，应为 0
```

界面文字以简体中文为键，新增文字要同时写进 `Resources/Localization/{en,ja,zh-Hant}.lproj/Localizable.strings`。

## 调试

```bash
LAUNCHUS_SNAPSHOT=/tmp/shot.png LAUNCHUS_QUERY=wx LAUNCHUS_FOLDER=工具 build/LaunchUS.app/Contents/MacOS/LaunchUS
open launchus://open
```

唤起后把界面渲染成 PNG。`LAUNCHUS_REAL=1` 改用真实视图截图；`LAUNCHUS_SHEET=custom|custom:<id>|icon:<id>|profile|whatsnew|guide:<步骤>|tip:<名称>` 打开对应的卡片（有模糊背景时截图要十几秒）。`LAUNCHUS_GUIDE=1` 启动时显示引导，`LAUNCHUS_CHECK_UPDATES=1` 启动时检查更新。

## 新功能的展示

- 首次运行：`Guide.swift` 的引导。
- 升级后：`Discovery.swift` 的「新功能」卡片。改了 `WhatsNew.features` 就把 `WhatsNew.edition` 加一，只修 bug 的版本不要动它。
- 用到时：`Tip`，每条只出现一次。

## 发布与自动更新

App 用 [Sparkle](https://sparkle-project.org) 检查更新，更新源是 `update.conf` 里 `DOWNLOAD_URL` 下的 `appcast.xml`。发布由维护者负责。

## 数据

都在 `~/Library/Application Support/LaunchUS`：`layout.json`（布局）、`meta.json`（别名 / 隐藏 / 自选图标）、`custom.json`（启动项）、`profiles.json`（其他布局方案）、`Icons/`、`Background/`、`Backups/`。删除 `layout.json` 即回到首次运行状态。
