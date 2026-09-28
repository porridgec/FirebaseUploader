# AGENTS.md

FirebaseUploader —— 把 iOS `.ipa` 上传到 Firebase App Distribution 并分发到测试组的工具，包含两个实现：

- `app.py` —— 原单文件 macOS Tkinter GUI（Python），封装 `firebase` CLI。不是 git 仓库；没有配置测试、lint 或构建工具。
- `FirebaseUploaderMac/` —— Swift 版重写（SwiftUI + Swift Package，macOS 14+），功能与 `app.py` 对等。开发用 `swift build` / `swift run`（在 `FirebaseUploaderMac/` 目录下执行）；打包 .app 用 `./build-app.sh`（release 编译 + 图标 + ad-hoc 签名，产物在 `dist/FirebaseUploaderMac.app`）。仅标准库，无第三方依赖。

两版共用同一份缓存 `~/.firebase_uploader_cache.json`，键名一致，历史/上次选择互通。

## 运行方式

- `python3 app.py` —— 仅用标准库（tkinter、subprocess、json），无需安装依赖。
- 要求 PATH 中有 `firebase` CLI（`npm i -g firebase-tools`）。所有 firebase 操作都是通过子进程调用 CLI 完成的，代码里没有使用 Firebase API/SDK。
- 状态持久化在 `~/.firebase_uploader_cache.json`（project/app/group 选择、上次 release mark、上传历史，上限 200 条）。`_load_cache`/`_save_cache` 对缺失/损坏的文件会容错返回 `{}` —— 修改时请保留这种宽容行为。

## 结构

Python 版所有代码都在 `app.py` 里：模块级辅助函数（`run_cmd`、`safe_ui`、`parse_console_links`）和一个 `App(tk.Tk)` 类。

Swift 版（`FirebaseUploaderMac/Sources/FirebaseUploaderMac/`）：

- `FirebaseUploaderApp.swift` —— `@main` 入口，窗口默认 980x820、最小 900x760（与 Tk 版一致）。
- `AppModel.swift` —— `@MainActor ObservableObject`，全部状态与动作（对等 Tk 版的 App 类）。
- `FirebaseCLI.swift` —— `Process`/`Pipe` 流式执行 firebase 命令（对等 `run_cmd`）；firebase 定位会先查 PATH 再兜底搜索 homebrew/volta/nvm/fnm 目录（GUI 启动不继承 shell PATH，且子进程 PATH 也补齐以保证 `env node` 可用）。
- `FirebaseModels.swift` —— 防御式 JSON 解析。
- `CacheStore.swift` —— 缓存读写，键名与 Python 版完全一致。
- `ContentView.swift` —— SwiftUI 界面，中文文案。左右分栏（HSplitView）：左栏核心流程（Project/App/Groups/Files/Release mark/分发），右栏 Upload History + Log；工具栏放版本检测/登录/刷新 Projects。选完 project 自动刷 apps、选完 app 自动刷 groups（视图层 onChange 链触发，`refreshApps(auto:)` 静默模式不弹窗）。
- `FirebaseUploaderApp.swift` —— `@main` 入口，窗口默认 1060x820、最小 900x760；`CommandGroup(replacing: .newItem)` 移除了 File/New Window（多窗口各有独立 AppModel，会写同一份缓存互相干扰），不要恢复它。

## 约定与坑

- **所有用户可见文案均为简体中文**（按钮、对话框、错误提示）。新增 UI 文案时保持一致。
- **Tk 线程安全是核心规则**：耗时 CLI 调用在 daemon 线程中执行，worker 线程里任何 UI 操作都必须经过 `safe_ui(root, fn)`（即 `root.after(0, fn)`）。新增命令时参照 `refresh_projects`/`distribute` 中已有的 `worker()` + `safe_ui` 模式。
- **firebase `--json` 输出解析**：CLI 会在 JSON 前打印约 2 行非 JSON 内容，所以解析时会做 `"\n".join(lines[2:])`。且 JSON 结构随 firebase-tools 版本变化 —— 解析代码会尝试多个键（`result` / `projects` / `apps` / 嵌套 dict），都不匹配时弹出中文"解析失败"对话框并附原始输出。修改时保持这种防御式风格。
- **登录是两段式**（firebase-tools 的非交互流程，GUI 的 stdin 非 TTY 自动触发）：`firebase login` 打印授权 URL 并退出（codeVerifier 存在 CLI 自己的 configstore）；用户从网页拿到授权码后，第二段跑 `firebase login <授权码>` 完成登录。AppModel 的 `startLogin`/`submitLoginCode` 实现此闭环，登录成功后自动刷新 Projects。注意 `login [auth_code]` 的位置参数形式是官方支持的，不要改成 stdin 粘贴方案（CLI 的交互 prompt 在非 TTY 下不可用）。
- **登录态先用 `firebase login:list` 探测**：非交互的 `firebase login` 会跳过 "Already logged in" 检查、直接生成新授权链接，所以点"登录"必须先跑 `login:list`——已登录则展示账号（含多账号 `login:use` 切换），未登录才进入两段式。解析 CLI 输出里的 email/URL 前都要 `stripANSI` 去颜色码。
- **`--groups` 必须合并成一个逗号分隔的值**，不能重复传参（`",".join(selected_groups)`）—— firebase-tools 期望逗号分隔列表（`distribute` 中已标注 IMPORTANT）。
- Swift 版额外缓存键：`recent_uploaders`（最近用过的上传人，上限 5，Python 版会忽略此键）。
- 日志是结构化的（`LogLine`：command/error/output 三色 + 可点击链接），firebase 进度条的 `\r` 覆盖行在 `appendLog` 里拆成独立行，上传百分比由 `updateProgress(from:)` 用正则取最后一个 `NN%`。
- **Combobox/列表框的值把 id 放在第一个 token**（如 `"projectId  displayName"`）；提取方式是 `val.split()[0]`。新增列表时必须保持机器可读的 id 在最前面。
- **Release notes 格式**为 `"{mark} [{uploader}]"`（uploader 为空时只含 mark，不带空括号）；默认 uploader 从缓存 `recent_uploaders` 恢复，无则留空、由占位提示引导输入。预览输入框是只读的，通过 `StringVar` trace 自动派生。
- `pick_ipa` 的初始目录是动态的：`~/Downloads/ios-build-output` 存在才用，否则回退 `~/Downloads` —— 不要假设前者存在，也不要写死绝对路径。
- `:distribute` 返回 404 时有专门的提示对话框（组名不匹配 vs. 权限不足）—— 修改该处错误处理前先看 `distribute` 末尾的逻辑。

## 验证改动

Python 版运行 `python3 app.py`、Swift 版 `swift run`，走一遍受影响的流程。"检测 firebase 版本" 是成本最低的端到端冒烟测试（走完整的 线程→CLI→日志 管线）。

Swift 版注意事项：

- 开发用 `swift run`（命令行启动，PATH 正常）；打包发布用 `./build-app.sh`，产物 `dist/FirebaseUploaderMac.app`（ad-hoc 签名，仅本机可运行）。
- 从 Finder/Dock 启动 .app 时进程不继承 shell 的 PATH（不含 /opt/homebrew/bin），firebase 依赖 `FirebaseCLI.searchDirectories()` 的兜底搜索找到；改 CLI 定位逻辑时别删这些兜底目录，子进程 PATH 也靠它补齐（`firebase` 启动脚本需要 `env node`）。
- firebase CLI 启动时会把 `firebase-debug.log` 写到进程工作目录（或 `FIREBASE_DEBUG_PATH` 环境变量），目录不可写会直接崩溃（"Unable to obtain permissions for firebase-debug.log"）；从 `open` 启动的 .app 工作目录是 `/`。`FirebaseCLI.run` 里已固定子进程 CWD 和 `FIREBASE_DEBUG_PATH` 到 `~/.firebase-uploader`，改动进程启动逻辑时必须保留。
- 应用图标由 `scripts/make-icon.swift` 用 CoreGraphics 绘制（渐变圆角方块 + 上传箭头），1024 PNG 缓存在 `build/`；改了图标脚本要删掉 `build/AppIcon1024.png` 重跑 `build-app.sh` 才会生效。
- Package 用 swift-tools-version 6.0 + `.swiftLanguageMode(.v5)`：保留 Swift 5 语言模式，避免严格并发检查的大改造。
- 本机 SDK（macOS 26.4）的 SwiftUI 没有 `windowDefaultSize`，用的是 `defaultSize(width:height:)`（macOS 13+，未弃用）；不要"顺手升级"这个修饰符名。脚本模式下 `CGPath(roundedRect:cornerRadius:)` 便捷初始化器也不可用，要用 `cornerWidth:cornerHeight:`。
- **发布二进制的隐私注意**：Swift 反射元数据/DWARF 会把构建时的绝对路径编进二进制（默认 `strings` 扫不出，要 `strings -a`）。仓库只发布源码；若要发布 release 二进制，必须在不含个人路径的目录（如 `/tmp` 下 clone）构建后再验证。

## 开源卫生

- 仓库**不含**任何凭据/邮箱/个人姓名/公司信息；保持这个约定（新增代码、文案、脚本时同样适用）。
- `.gitignore` 排除了 `.build/`、`build/`、`dist/`、`__pycache__/`、`.zcode/`、`.DS_Store` 等本地产物，改完代码不要把它们加进版本控制。
