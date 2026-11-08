# 小组件插件规范（第 1 版）

LaunchUS 的小组件和 App 图标一起放在网格里，占 2×2、4×2 或 4×4 格，可以拖动、改大小、移除。
小组件分两种：

- **系统小组件**：LaunchUS 自带，ID 以 `launchus.` 开头：
  - 时间与日程：时钟与日期（`launchus.clock`）、指针时钟（`launchus.analog-clock`）、日历与提醒事项（`launchus.calendar`）、节日倒数（`launchus.countdown`）、时间进度（`launchus.progress`）。
  - 实用工具：便签（`launchus.note`）、常用应用（`launchus.apps`）、计时器（`launchus.timer`）、快捷操作（`launchus.actions`）。
  - 系统：系统状态（`launchus.system`）、电池（`launchus.battery`）、网络（`launchus.network`）、存储空间（`launchus.storage`）。
- **插件小组件**：任何人用 HTML / CSS / JavaScript 写的外置插件，本文就是它的规范。

在启动台空白处右键 →「添加小组件…」打开小组件库，或者用链接 `launchus://widgets`。库里列出全部系统小组件和已安装的插件，可以预览每种尺寸，再添加到当前页。

## 1. 插件包

一个插件是一个以 `.launchuswidget` 结尾的文件夹：

```
weekend.launchuswidget/
├── manifest.json   必需：插件说明
├── index.html      必需：画小组件的页面（文件名可在 manifest 里改）
├── icon.png        可选：小组件库里显示的图标，建议 256×256
└── …               页面用到的其他文件（CSS、JS、图片、字体）
```

### 安装

任选一种：

1. 小组件库里点「安装插件…」，选中插件文件夹；
2. 把插件文件夹拖进小组件库；
3. 直接放进 `~/Library/Application Support/LaunchUS/Widgets/`（库里点「打开插件文件夹」）。

LaunchUS 会监视这个文件夹，增删插件立刻生效。改了插件里的文件后，打开一次小组件库就会重新扫描，网格上的页面也会重新载入。
安装同一个 `id` 的插件会替换旧的（旧的移到废纸篓）。库里可以把插件「移到废纸篓」；网格上用了这个插件的小组件会显示「未安装的小组件」，装回来就恢复。

## 2. manifest.json

```json
{
  "spec": 1,
  "id": "com.example.weekend",
  "name": { "en": "Weekend", "zh-Hans": "周末倒计时", "ja": "週末まで" },
  "description": { "en": "Days left until the weekend.", "zh-Hans": "离周末还有几天。" },
  "version": "1.0.0",
  "author": "Example",
  "homepage": "https://example.com",
  "icon": "icon.png",
  "symbol": "calendar.badge.clock",
  "sizes": ["small", "medium"],
  "entry": "index.html",
  "refresh": 60,
  "permissions": [],
  "open": "https://example.com"
}
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `spec` | 否 | 规范版本，目前是 `1`，省略按 1。比 App 支持的新时插件不载入，库里提示需要更新 LaunchUS。 |
| `id` | 是 | 反向域名，至少两段，只用 ASCII 字母、数字、`-`、`_`，不超过 128 字符。不能以 `launchus.` 开头（留给系统小组件）。网格上的小组件靠它找到插件，发布后不要改。 |
| `name` | 是 | 名字。字符串，或「语言代码 → 文字」的对象。按 Mac 的首选语言匹配（`zh-Hans-CN` → `zh-Hans` → `zh`），找不到用 `en`，再找不到用任意一个。 |
| `description` | 否 | 一两句说明，格式同 `name`，显示在小组件库。 |
| `version`、`author`、`homepage` | 否 | 显示在小组件库。 |
| `icon` | 否 | 插件文件夹里的图片路径。 |
| `symbol` | 否 | 没有 `icon` 时用的 SF Symbol 名字，默认 `puzzlepiece.extension`。 |
| `sizes` | 是 | 支持的尺寸，`small`（2×2）、`medium`（4×2）、`large`（4×4）中的一个或几个。不认识的值会被忽略；一个都不剩时插件不载入。 |
| `entry` | 否 | 页面路径，默认 `index.html`，必须在插件文件夹里。 |
| `refresh` | 否 | 秒数。启动台打开期间每隔这么久发一次 `refresh` 事件（最少 1 秒）。 |
| `permissions` | 否 | 权限列表，见第 4 节。不认识的权限会被忽略。 |
| `open` | 否 | 点击小组件时打开的链接，`https:` 或其他 App 的 URL scheme。不允许 `file:`、`javascript:`、`data:`。 |
| `openApp` | 否 | 点击小组件时打开的 App 的 bundle ID，比 `open` 优先。 |

没有 `open` 和 `openApp` 时点击小组件不做任何事。

## 3. 页面

页面在一个不接收鼠标的网页视图里显示，铺满整张卡片：

- **点击、拖动、长按都归启动台**：点击打开 `open` / `openApp`，拖动挪位置，长按进入编辑。页面里的按钮、链接、滚动都不会响应——把小组件当成一块会自己更新的屏幕来设计。
- **背景要透明**：卡片的玻璃 / 半透明底由 LaunchUS 画，页面别设 `body` 背景色（或用半透明色）。
- **边距自己留**：系统小组件的内边距是卡片短边的 9%，约等于 `calc(var(--launchus-unit) * 0.18)`。
- **跟着卡片缩放**：同一个尺寸在不同显示器、不同网格密度下大小不同。用 `--launchus-unit` 定字号和间距，不要写死像素。
- **深色 / 浅色**：全屏启动台里卡片总是深色；窗口模式跟随系统外观。看 `launchus.theme` 或 `<html data-theme>`，`color-scheme` 已经设好。
- **页面只能读自己文件夹里的文件**，不能跳转到别的页面；本地存储（`localStorage` 等）不会保留到下次载入。

### 页面拿到的 CSS 变量和属性

LaunchUS 在页面脚本运行之前给 `<html>` 设好：

| 名字 | 例子 | 说明 |
|---|---|---|
| `--launchus-unit` | `78px` | 一格的尺度。小尺寸卡片宽约 2 unit，中尺寸约 4 × 2 unit。系统小组件的正文是 0.12–0.16 unit，大数字 0.5 unit。 |
| `--launchus-width` / `--launchus-height` | `156px` | 卡片的宽高。 |
| `data-size` | `small` | 当前尺寸，可以写 `html[data-size="medium"] .detail { display: block }`。 |
| `data-theme` | `dark` | `dark` 或 `light`。 |

### `window.launchus`

```ts
interface LaunchUS {
  readonly spec: 1
  readonly size: "small" | "medium" | "large"
  readonly width: number        // 卡片宽，pt
  readonly height: number       // 卡片高，pt
  readonly unit: number         // 同 --launchus-unit，pt
  readonly theme: "dark" | "light"
  readonly locale: string       // Mac 的首选语言，如 "zh-Hans-CN"
  readonly visible: boolean     // 启动台是否打开着
  on(event: "change" | "show" | "hide" | "refresh", fn: (detail?: any) => void): void
  off(event: string, fn: Function): void
  system(): Promise<SystemSample>   // 需要 "system" 权限
}

interface SystemSample {
  cpu: number                                   // 0–1，全部核心
  memory: { used: number, total: number }       // 字节
  disk:   { used: number, total: number }       // 字节，启动磁盘
  battery: { level: number, charging: boolean } | null   // level 0–1；没有电池时为 null
  network: { download: number, upload: number } // 字节 / 秒
  uptime: number                                // 开机以来的秒数
}
```

事件：

| 事件 | 什么时候 |
|---|---|
| `change` | 尺寸、卡片大小或深浅色变了，参数是新的状态。 |
| `show` / `hide` | 启动台打开 / 收起。收起期间请停掉动画和轮询。 |
| `refresh` | 启动台打开期间每 `refresh` 秒一次（manifest 里设了才有）。 |

`launchus` 在页面任何脚本之前就已存在，不需要等待。

## 4. 权限

| 权限 | 允许 | 不声明时 |
|---|---|---|
| `network` | 访问网络：`fetch`、`XMLHttpRequest`、WebSocket、远程图片和字体。 | 一切 `http(s)`、`ws(s)`、`ftp` 请求都被拦下。 |
| `system` | 调用 `launchus.system()` 读 CPU、内存、磁盘、电池和网速。 | `launchus.system()` 返回被拒绝的 Promise。 |

小组件库会把插件的权限显示给用户（「可以联网」「不联网」「读取系统状态」）。只申请真正用到的权限。

插件拿不到的东西：本地文件（自己文件夹以外）、日历、通讯录、剪贴板、启动台的布局和 App 列表、打开链接或 App（只能由用户点击触发 `open` / `openApp`）。

## 5. 性能

- 启动台收起时 LaunchUS 停发 `refresh`，并发 `hide`；请在 `hide` 时停掉 `setInterval` 和 `requestAnimationFrame`，`show` 时恢复。
- 每个小组件是一个网页视图。保持页面轻：不要引入大型框架，不要持续动画。
- 小组件库里的预览也是真实运行的页面。

## 6. 版本兼容

- 新版 LaunchUS 读得懂旧版插件。规范只做向后兼容的扩展：加字段、加权限、加事件。
- 不兼容的改动会把 `spec` 加 1，旧版 LaunchUS 遇到更高的 `spec` 不载入插件。
- 插件可以检查 `launchus.spec` 和某个方法是否存在，在旧版上降级。

## 7. 示例

[`docs/widgets/`](widgets/) 里有两个能直接安装的示例：

- `weekend.launchuswidget`：离周末还有几天和今年过了多少，不需要任何权限，演示多语言名字、`data-size` 和 `--launchus-unit`。
- `cpu-graph.launchuswidget`：CPU 和内存的走势图，用 `system` 权限和 `refresh`，在 `hide` 时暂停。

最小可用的插件：

```json
{ "id": "com.example.hello", "name": "Hello", "sizes": ["small"] }
```

```html
<!doctype html>
<meta charset="utf-8">
<style>
  body { margin: 0; height: 100vh; display: grid; place-items: center;
         font: 600 calc(var(--launchus-unit) * 0.3) -apple-system, sans-serif; color: white; }
  html[data-theme="light"] body { color: black; }
</style>
<body>Hello</body>
```
