# Markdown Studio for macOS

一个原生 macOS Markdown 编辑器，支持：

- GFM / CommonMark 实时预览：表格、任务清单、嵌套列表、删除线、链接、图片与代码块等
- 打开、编辑、保存和另存为 `.md` 文件
- 新建文件默认保存到 `~/Downloads`，命名为 `note_日期.md`
- 导出多页 A4 PDF；导出时可选风格和 11–26 pt 正文字号
- 编辑器与预览按滚动进度同步

## 下载并运行

在仓库的 [Releases](../../releases) 页面下载 `Markdown-Studio-macOS.zip`，解压后将 `Markdown Studio.app` 拖到“应用程序”文件夹，再双击打开。

若 macOS 因为这是本地签名的应用而阻止打开：在 Finder 中按住 Control 点击应用，选择“打开”，然后再次确认即可。

## 从源码构建

需要 macOS 14 或以上，以及 Xcode Command Line Tools。

```zsh
git clone https://github.com/Zerong-Sun/markdowneditor.git
cd markdowneditor
./build-app.sh
```

构建完成后双击 `Markdown Studio.app`。本项目内置 GFM 解析器，因此预览不依赖网络连接。
