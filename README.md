# Markdown Studio for macOS

一个原生 macOS Markdown 编辑器，支持源码编辑、双栏实时预览、仅读取模式、渲染编辑和多页 PDF 导出。内置 Markdown 语法示例、GFM 解析器和 KaTeX，无需联网即可渲染本地正文与公式；网络图片仍需要网络。

当前版本：**v1.5.1（build 7）**。

[下载 Mac 应用](https://github.com/Zerong-Sun/markdowneditor/releases/download/v1.5.1/Markdown-Studio-macOS.zip) · [版本说明](https://github.com/Zerong-Sun/markdowneditor/releases/tag/v1.5.1) · [SHA-256 校验文件](https://github.com/Zerong-Sun/markdowneditor/releases/download/v1.5.1/SHA256SUMS.txt)

## 下载与安装

预编译应用适用于 **Apple Silicon（M 系列）Mac，macOS 14 或以上**。Intel Mac 请从源码构建；macOS 14 和 Intel 尚未实机验证。

1. 下载 `Markdown-Studio-macOS.zip` 并解压。
2. 将 `Markdown Studio.app` 拖到“应用程序”文件夹。
3. 双击打开应用，按 `⌘O` 选择 Markdown 文件，也可以将文件拖入编辑区或应用图标。

升级时先保存文档并正常退出旧版，再替换“应用程序”中的应用。替换应用包不需要删除或移动自己的 Markdown 文件。下载包内附有[安装说明](docs/INSTALL_MACOS.md)和第三方声明。

下载包使用本地临时签名，**未经过 Apple 公证**。请确认下载来源并核对校验值；如被系统阻止，按 [Apple 的安全打开指引](https://support.apple.com/zh-cn/102445)在“系统设置 → 隐私与安全性”中确认，不要关闭系统安全保护。

将 ZIP 和 `SHA256SUMS.txt` 下载到同一目录后，可在该目录运行：

```zsh
shasum -a 256 -c SHA256SUMS.txt
```

应显示 `Markdown-Studio-macOS.zip: OK`。所有历史版本见 [Releases](https://github.com/Zerong-Sun/markdowneditor/releases)。

## 主要功能

- **Markdown 语法**：GFM / CommonMark 表格、任务清单、嵌套列表、删除线、链接、图片、行内代码和代码块；KaTeX 行内及块级公式。启动示例列出支持与尚未支持的扩展。
- **三种显示模式**：“仅编辑”“双栏”“仅渲染”。仅渲染隐藏左侧源码、正文只读；模式会记住。双栏预览跟随左侧滚动进度。
- **渲染编辑**：在双栏模式启用“渲染编辑”，直接在右侧正文输入。按块回写 Markdown，保留未修改块的源码、引用定义和代码围栏；HTML 容器块需在源码侧编辑。
- **本地文档与标签**：Finder“打开方式”、拖入文件、`⌘O` 或命令行打开；多个文件显示独立标签。支持 `.md`、`.markdown`、`.mdown`、`.mkdn`、`.mkd`、`.txt`，中文/空格路径、UTF-8 和带 BOM 的 UTF-16/UTF-32。
- **编辑状态保护**：切换模式或标签保留源码光标与独立撤销历史；关闭文档和退出时询问未保存更改。重复打开同一文件切回已有标签，不覆盖草稿。
- **保存保护**：检测外部修改/删除，阻止静默覆盖；另存为不会覆盖其他打开的标签。新建默认保存到 `~/Downloads`，如 `note_2026-10-24_103000.md`，重名时自动加后缀。
- **PDF 导出**：多页 A4、四种风格、11–26 pt 字号、可选择文字、公式、可点击链接和本地图片；支持进度、取消、超时保护与原子输出，不依赖打印机。
- **链接与 HTML 安全**：网页链接在默认浏览器打开，本地 Markdown 链接在应用中打开，不替换当前预览；过滤脚本、危险属性和任意应用 URL 协议。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建 / 打开 | `⌘N` / `⌘O` |
| 保存 / 另存为 | `⌘S` / `⇧⌘S` |
| 仅编辑 / 双栏 / 仅渲染 | `⌘1` / `⌘2` / `⌘3` |
| 导出 PDF | `⌘P` |
| 撤销 / 重做（编辑区） | `⌘Z` / `⇧⌘Z` |
| 关闭当前文档 | `⌘W` |

## 导出 PDF

1. 按 `⌘P` 或点击“导出 PDF”。
2. 选择“简洁白纸 / 暖色纸张 / 书籍衬线 / 夜间墨黑”和正文字号，点击“继续”。
3. 在保存面板选择文件名与位置；设置会记住。
4. 底栏显示导出进度，可取消。完成后点击“打开 PDF”查看结果。仅渲染模式同样可以导出，未保存的正文也可导出。

若保存遇到“文件已被其他程序修改”的提示，草稿仍保留在标签中。要保留草稿，请先另存为新文件，再打开原文件对照；要舍弃草稿并读取磁盘版本，使用文件菜单“从磁盘重新载入”，在确认框选择“不保存”。

## v1.5.1 更新

- 修复渲染编辑重写整篇文档、丢失引用定义/HTML/嵌套代码围栏的问题。
- 修复含下划线公式的解析，以及空文档渲染编辑和中文组合输入的同步问题。
- 修复切换模式/标签后的光标、撤销/重做与未保存状态同步。
- 增加保存冲突保护；统一识别大小写路径、软链接和硬链接，防止重复标签互相覆盖。
- 修复预览链接带走当前页面，以及控制字符混淆 URL 过滤的问题。
- 修复 PDF 超长单词、表格单元格和宽公式的横向裁切。

本机通过 **543 项检查**，包含实际 AppKit / SwiftUI / WebKit 集成测试；65 节长文导出为 **23 页 A4**，验证了四种风格、80 行表格、90 行代码与 32 项宽公式。完整记录和未覆盖范围见[六方面质量审计与修复清单](docs/QUALITY_AUDIT.md)。

## 从源码构建

需要 macOS 14 或以上，以及支持 Swift 6 的 Xcode Command Line Tools。

```zsh
git clone https://github.com/Zerong-Sun/markdowneditor.git
cd markdowneditor
./build-app.sh
```

构建完成后打开脚本输出的应用路径（默认 `~/Library/Caches/MarkdownStudio/Markdown Studio.app`），或将它复制到“应用程序”。构建缓存与签名产物位于本机缓存目录，避免 iCloud 同步干扰。可用 `MARKDOWNSTUDIO_APP_PATH` 指定应用输出位置、`MARKDOWNSTUDIO_BUILD_CACHE` 指定构建缓存。

## 验证

```zsh
./scripts/test.sh
open -a "/Applications/Markdown Studio.app" "Tests/Fixtures/中文 打开测试.md"
```

测试脚本检查真实文件与文档模型，并运行 WebKit PDF 导出、原生设置面板、三种显示模式、富文本回写和原生撤销/重做。默认清理测试产物；设置 `MARKDOWNSTUDIO_PDF_TEST_OUTPUT=/absolute/path` 可保留 PDF 和界面快照，首次请使用空目录。543 为检查断言数，不代表代码行覆盖率。

验证记录：[v1.5.1 质量审计](docs/QUALITY_AUDIT.md) · [v1.5 阅读模式与导出](docs/READING_AND_PDF_FIXES.md) · [v1.4 文件打开修复](docs/FILE_OPENING_FIXES.md)。

## 已知限制

- 单个文本文件最多 20 MiB，PDF 最多 1000 页。
- 过宽公式导出时缩小以保留全部内容，复杂长公式建议用 `aligned` 手动分行；长表格跨页不自动重复表头。
- 渲染编辑规范化实际修改的块，不等同于任意 Markdown/HTML 的逐字符无损富文本编辑；需要精确控制格式时请使用源码编辑。
- 启动示例标出的 Mermaid、脚注等额外扩展目前不提供专用渲染，不将示例语法视为已实现功能。
- 系统远程保存面板最终的鼠标确认未自动化测试；中文组合输入使用 WebKit 组合事件验证，不代表逐一实测所有输入法。

第三方组件及其来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
