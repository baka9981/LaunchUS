# 开发说明

Swift 6 + SwiftUI + AppKit，SwiftPM 构建，需要 macOS 26 和 Xcode 26。

## 构建与测试

```bash
./scripts/run.sh            # 构建 build/LaunchUS.app 并启动
./scripts/build.sh          # 只构建（release 构建会生成快捷指令元数据）
swift test --parallel       # 单元测试
./scripts/l10n-missing.sh   # 检查 en / ja / zh-Hant 是否缺翻译，应为 0
```

Apple 芯片和 Intel 是两个独立的 App，不做通用二进制，各自只有一半大小。`ARCH=x86_64 ./scripts/build.sh` 构建 Intel 版到 `build/x86_64/LaunchUS.app`，在 Apple 芯片的 Mac 上可以通过 Rosetta 直接运行。Intel 版读自己的更新源 `appcast-intel.xml`。release 构建会去掉符号表，符号另存为旁边的 `.dSYM`，用来看崩溃日志，不随 App 发布。

在 Rosetta 下跑测试（`swift test` 的测试助手只有 arm64）：

```bash
swift build --build-tests --arch x86_64
arch -x86_64 "$(xcrun -f xctest)" .build/out/Products/Debug/LaunchUSTests.xctest
```

界面文字以简体中文为键，新增文字要同时写进 `Resources/Localization/{en,ja,zh-Hant}.lproj/Localizable.strings`。

## 代码结构

`Sources/LaunchUS/` 按功能分目录（SwiftPM 会递归收集，加文件不用改配置）：

| 目录 | 内容 |
|---|---|
| `App/` | 启动入口和全局部件：`AppDelegate`、`launchus://` 链接、快捷指令、全局快捷键和触发方式、权限、Sparkle 更新、安装位置、诊断、卡顿记录 |
| `Launcher/` | 启动台本身：窗口（`LauncherController`）、界面（`LauncherView`、`Controls`、`Menus`）、状态（`LauncherModel` 和它按主题拆开的扩展）、文件夹分组、隐藏 App、整理模式、壁纸、Dock 角标 |
| `Layout/` | 布局数据：`layout.json`、布局方案、自动备份、iCloud 同步、导入系统启动台、自定义项目 |
| `Widgets/` | 网格里的小组件：系统小组件（时钟、系统状态、日历）、插件注册与载入、小组件库界面。插件规范见 [WIDGETS.md](WIDGETS.md) |
| `Apps/` | 已安装的 App：扫描和图标、新装标记、信息卡、App 管理、重复清理、卸载、App 更新检查 |
| `Search/` | 搜索框：匹配、文件搜索、计算器、系统设置面板、空格列表 |
| `AI/` | AI 聊天（网关、界面、出错说明、工具、历史）和 MCP 服务器 |
| `Settings/` | 设置项（`Settings`、`UserDefaults.app`）和设置窗口 |
| `Onboarding/` | 首次引导和新功能提示 |

## 调试

```bash
LAUNCHUS_SNAPSHOT=/tmp/shot.png LAUNCHUS_QUERY=wx LAUNCHUS_FOLDER=工具 build/LaunchUS.app/Contents/MacOS/LaunchUS
open launchus://open
```

唤起后把界面渲染成 PNG。`LAUNCHUS_REAL=1` 改用真实视图截图；`LAUNCHUS_SHEET=custom|custom:<id>|icon:<id>|profile|whatsnew|guide:<步骤>|tip:<名称>` 打开对应的卡片（有模糊背景时截图要十几秒）。演示截图：`LAUNCHUS_DEMO=1` 只列系统自带的 App（/System 里的）、不显示引导，`LAUNCHUS_WALLPAPER=<图片>` 代替桌面壁纸，再加 `CFFIXED_USER_HOME=<空目录>` 用一份全新的布局。演示模式的设置存在单独的 `local.launchus.LaunchUS.demo` 里、每次启动清空（`UserDefaults.app`；`CFFIXED_USER_HOME` 隔离不了设置），不会把“只有系统 App”写进真实设置、让其他 App 全变成新装。`LAUNCHUS_SHOW=1` 启动后直接打开（录屏用，加 `LAUNCHUS_FOLDER` 再打开那个文件夹），`LAUNCHUS_GUIDE=1` 启动时显示引导，`LAUNCHUS_CHECK_UPDATES=1` 启动时检查更新。

卡顿：`LAUNCHUS_HITCHES=/tmp/hitch.log` 让启动台每次掉帧（一帧超过刷新间隔的 1.8 倍）都记一行：时间、耗时、掉了几帧、当时的页码 / 文件夹 / 搜索状态（`HitchLog.swift`）。配合 `sample <pid> 2` 看主线程在忙什么。

AI 聊天：`LAUNCHUS_CHAT=1` 载入示例对话（`=empty` 打开空对话，显示建议和最近的对话记录；`=error` 显示一条出错的回答；记录存在 Application Support/LaunchUS/Chats（其他方案的在 `Profiles/<方案名>/Chats`），截图运行不写入），`LAUNCHUS_ASK=<问题>` 真的发一条（用设置里的网关；`LAUNCHUS_AI_KEY` 可临时换密钥），`LAUNCHUS_DELAY=<秒>` 推迟截图等回答流完，`LAUNCHUS_SETTINGS=ai` 打开对应的设置页（`LAUNCHUS_TUNER=background|motion` 打开外观的调节面板，`background:<n>` 同时套用第 n 个方案）。debug 构建直接运行时加载不了 Sparkle，截图和 MCP 测试请用 `scripts/build.sh release` 的产物。

## AI 与 MCP

- `AIChat.swift`：网关（`AIClient`，OpenAI 兼容和 Anthropic 两种流式格式，含工具调用）、对话（`ChatSession`，每个回答最多 8 轮工具调用）和聊天界面。密钥存在钥匙串（`AIKey`）。
- `AITools` 决定 AI 能用哪些工具：`readOnly` 直接运行，`actions` 先弹确认（「本次对话都允许」可跳过），`risky`（退出 App）每次都确认；设置里的「让 AI 操作 LaunchUS」可关掉或只允许查询。
- 工具分两处执行：`LauncherModel+AITools.swift` 的 `runLocalTool` 在 App 内直接改布局（`get_layout`、`move_app`、`create_folder`、`rename_folder`、`dissolve_folder`、`hide_app`，以及 `switch_layout`、`open_group`），只给内置聊天用；其余交给 `MCPServer.call`。
- `MCPServer.swift`：`LaunchUS --mcp` 是 stdio 上的 JSON-RPC MCP 服务器，不显示界面，只读布局文件；要动启动台的操作通过 `launchus://` 链接交给正在运行的 App。新增工具时同步更新 `AITools` 的分组、`title` 和 `symbol`，以及设置页 MCP 一节的工具列表。

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | build/LaunchUS.app/Contents/MacOS/LaunchUS --mcp
```

## 新功能的展示

- 首次运行：`Guide.swift` 的引导。
- 升级后：`Discovery.swift` 的「新功能」卡片。改了 `WhatsNew.features` 就把 `WhatsNew.edition` 加一，只修 bug 的版本不要动它。
- 用到时：`Tip`，每条只出现一次。

## 发布与自动更新

App 用 [Sparkle](https://sparkle-project.org) 检查更新，更新源是 `update.conf` 里 `DOWNLOAD_URL` 下的 `appcast.xml`。发布由维护者负责。

更新分正式版和 Beta 两个渠道，用同一份更新源：正式版是 `appcast.xml` 的第一项，Beta 是后面带 `<sparkle:channel>beta</sparkle:channel>` 的那一项，只有在「设置 › 通用」打开「接收 Beta 版」的 Mac 才会收到。Beta 用正常的版本号，转正式版时不重新构建，安装过的人不会再收到一次同样的更新。

```bash
./scripts/release.sh 1.8.0            # 打包，正式版和 Beta 一样
./scripts/publish.sh --beta 1.8.0     # 作为 Beta 发布，安装包在 v1.8.0/ 里，LaunchUS.dmg 不变
./scripts/publish.sh --promote 1.8.0  # 转为正式版（GitHub 上的 prerelease 也改成正式版）
./scripts/publish.sh --withdraw-beta  # 撤下 Beta，装了的人保留，下一个更新的版本出来时照常更新
./scripts/publish.sh 1.8.0            # 直接发布正式版；比它新的 Beta 保留，旧的撤下
```

`scripts/appcast.py` 负责合并两个渠道的更新源。

## 数据

都在 `~/Library/Application Support/LaunchUS`：`layout.json`（布局）、`meta.json`（别名 / 当前方案的隐藏 / 自选图标）、`custom.json`（启动项）、`profiles.json`（其他布局方案的页面、设置和隐藏名单）、`Icons/`、`Background/`、`Backups/`、`Profiles/<方案名>/`（其他方案自己的 `Backups/` 和 `Chats/`）。AI 密钥在钥匙串里，默认方案的账户名是 `apiKey`，其他方案是 `apiKey.<方案名>`。删除 `layout.json` 即回到首次运行状态。
