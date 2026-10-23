# Markdown Studio v1.5.1 安装说明

适用：Apple Silicon（M 系列）Mac，macOS 14 或以上。Intel Mac 请从源码构建；Intel 与 macOS 14 尚未实机验证。

## 安装或升级

1. 从 [v1.5.1 发布页](https://github.com/Zerong-Sun/markdowneditor/releases/tag/v1.5.1)下载 `Markdown-Studio-macOS.zip`，不要下载页面自动生成的源码包代替应用。
2. 升级前保存文档，正常退出旧版。不要强制结束有未保存更改的进程。
3. 解压 ZIP，将 `Markdown Studio.app` 拖到“应用程序”文件夹；已有旧版时替换应用包即可，无需删除 Markdown 文档。
4. 双击应用，按 `⌘O` 打开文件，或将 Markdown 文件拖入应用。

本下载包为本地临时签名，未经过 Apple 公证。请确认来源与 SHA-256；如果系统阻止打开，参照 [Apple 安全打开指引](https://support.apple.com/zh-cn/102445)完成确认，不要关闭系统安全保护。

## 校验下载

同时下载发布页的 `SHA256SUMS.txt`，与 ZIP 放在同一目录，在该目录运行：

```zsh
shasum -a 256 -c SHA256SUMS.txt
```

正确结果：`Markdown-Studio-macOS.zip: OK`。

## 使用

- `⌘1` 仅编辑，`⌘2` 双栏，`⌘3` 仅渲染阅读；双栏中可开启“渲染编辑”。
- `⌘N` 在下载目录创建 `note_日期.md`，`⌘S` 保存，`⇧⌘S` 另存为。
- `⌘P` 导出 PDF：选择风格与字号 → 继续 → 选择保存位置；完成后点击“打开 PDF”。
- 保存发生外部修改冲突时，草稿不会被清除；另存为新文件可保留草稿。

完整使用说明、限制与源码构建方法见 [项目 README](https://github.com/Zerong-Sun/markdowneditor/blob/v1.5.1/README.md)。第三方组件声明随下载包附带，也可在[仓库](https://github.com/Zerong-Sun/markdowneditor/blob/v1.5.1/THIRD_PARTY_NOTICES.md)查阅。
