# FirebaseUploader

把 iOS `.ipa` 上传到 [Firebase App Distribution](https://firebase.google.com/products/app-distribution) 并分发到测试组的 macOS 桌面小工具。封装官方 `firebase` CLI，不直接调用 Firebase API，也没有任何第三方依赖。

包含两个功能对等的实现：

| 实现 | 技术栈 | 运行方式 |
|---|---|---|
| `app.py` | Python 3 + Tkinter（仅标准库） | `python3 app.py` |
| `FirebaseUploaderMac/` | Swift + SwiftUI（Swift Package，macOS 14+，仅系统框架） | `swift run`（开发）/ `./build-app.sh`（打包 .app） |

两个实现共用同一份本地缓存 `~/.firebase_uploader_cache.json`（键名一致），历史记录与上次选择互通，可随意切换使用。

## 功能

- **Project / iOS App / Groups 选择**：下拉选择 Firebase 项目、自动过滤 iOS 应用、多选测试组（带搜索、全选/清空）
- **链式加载**：选完 project 自动刷新 Apps，选完 app 自动刷新 Groups
- **上传分发**：IPA + 可选 dSYM.zip，release notes 按 `mark [uploader]` 格式自动生成；未选组时确认"仅上传"；支持拖拽 `.ipa`/`.zip` 文件
- **上传进度**：实时解析 CLI 输出的百分比，显示进度条
- **两段式登录**（CLI 官方非交互流程）：应用内完成"授权链接 → 粘贴授权码 → 登录成功"闭环；已登录时显示当前账号并支持多账号切换
- **上传历史**：记录 release note 与时间（上限 200 条），双击历史行可回填 mark 与 uploader
- **富日志**：命令回显高亮、错误标红、链接可点击，支持复制链接/日志、自动滚动
- **中英文环境通用**：界面文案为简体中文

## 依赖

- macOS（Tkinter 版可在任意支持 tkinter 的平台运行）
- [firebase CLI](https://firebase.tools/)（`npm i -g firebase-tools`），无需在应用内配置任何密钥

## 构建

```bash
# Python 版
python3 app.py

# Swift 版（在 FirebaseUploaderMac/ 目录下）
swift build && swift run

# Swift 版打包 .app（release 编译 + 图标 + ad-hoc 签名，产物在 dist/）
./build-app.sh
```

> 从 Finder/Dock 启动 .app 时进程不继承 shell 的 PATH，应用内置了 homebrew/volta/nvm/fnm 目录的兜底搜索来定位 `firebase` 可执行文件。

## 数据与隐私

- 本工具**不收集、不上传任何数据**；所有状态都保存在本机：
  - 选择与历史：`~/.firebase_uploader_cache.json`（本工具管理）
  - 登录凭据：`~/.config/configstore/firebase-tools.json`（firebase CLI 自己管理，本工具不接触 token）
- 删除以上文件即可完全清除本工具留下的本地数据；登出账号请运行 `firebase logout`。

## License

[MIT](LICENSE)
