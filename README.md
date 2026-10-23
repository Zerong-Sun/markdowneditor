# Markdown Studio for macOS

一个原生 macOS Markdown 编辑器，支持：

- GFM / CommonMark 实时预览：表格、任务清单、嵌套列表、删除线、链接、图片、代码块与 KaTeX 数学公式
- “渲染编辑”模式：直接在右侧排版视图中输入，内容实时回写为 Markdown
- 工具栏可切换“仅编辑 / 双栏 / 仅渲染”：⌘1、⌘2、⌘3。“仅渲染”隐藏左侧源码，只显示不可编辑的排版正文；显示模式会自动记住
- Finder 双击、右键“打开方式”、拖到 Dock/编辑区、⌘O 和命令行传入文件均可打开文档
- 支持 `.md`、`.markdown`、`.mdown`、`.mkdn`、`.mkd`、`.txt`，支持中文/空格文件名、空文档、UTF-8 和带 BOM 的 UTF-16/UTF-32
- 同时打开多个文件会显示独立标签；重复打开同一文件会切回已有标签，保留未保存内容
- ⌘S 保存，⇧⌘S 另存为，⌘W 关闭当前文档；关闭标签、窗口和退出会提供保存/取消/不保存选项
- 新建文件默认保存到 `~/Downloads`，命名为 `note_日期.md`
- `⌘P` 导出多页 A4 PDF：文档内依次显示设置与保存面板；四种风格和 11–26 pt 字号会记住。直接生成可选中文字的矢量 PDF，不依赖打印机或系统打印窗口，支持取消、超时保护与原子输出
- 编辑器与预览按滚动进度同步

## 下载并运行

在仓库的 [Releases](https://github.com/Zerong-Sun/markdowneditor/releases/latest) 页面下载 `Markdown-Studio-macOS.zip`，解压后将 `Markdown Studio.app` 拖到“应用程序”文件夹，再双击打开。当前预编译版本适用于 Apple Silicon Mac、macOS 14 或以上；Intel Mac 可在本机从源码构建。

下载包使用本地临时签名，尚未经过 Apple 公证。若系统阻止打开，请先确认下载来源与发布页 SHA-256，再按 [Apple 的安全打开指引](https://support.apple.com/zh-cn/102445)在“系统设置 → 隐私与安全性”中完成确认；不要关闭系统安全保护。

## 从源码构建

需要 macOS 14 或以上，以及 Xcode Command Line Tools。

```zsh
git clone https://github.com/Zerong-Sun/markdowneditor.git
cd markdowneditor
./build-app.sh
```

构建完成后打开脚本输出的应用路径（默认 `~/Library/Caches/MarkdownStudio/Markdown Studio.app`），或将它复制到“应用程序”。构建缓存与签名产物放在本机缓存目录，避免 iCloud 同步干扰。可用 `MARKDOWNSTUDIO_APP_PATH` 指定输出位置。本项目内置 GFM 解析器，因此预览不依赖网络连接。

## 验证

```zsh
./scripts/test.sh
open -a "/Applications/Markdown Studio.app" "Tests/Fixtures/中文 打开测试.md"
```

测试脚本检查真实文件与文档模型，并运行实际 WebKit PDF 导出、原生设置面板和三种显示模式的集成测试。默认清理测试产物；可设置 `MARKDOWNSTUDIO_PDF_TEST_OUTPUT=/absolute/path` 保留 PDF 和界面快照。详见 [v1.5 阅读模式与导出验证](docs/READING_AND_PDF_FIXES.md) 和 [v1.4 文件打开修复记录](docs/FILE_OPENING_FIXES.md)。
