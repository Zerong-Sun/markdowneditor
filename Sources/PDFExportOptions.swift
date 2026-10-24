import AppKit

enum PDFExportStyle: String, CaseIterable {
    case lightSans, lightSerif, darkSans, darkSerif
    var name: String {
        switch self {
        case .lightSans: "白纸 · 无衬线"
        case .lightSerif: "白纸 · 衬线"
        case .darkSans: "墨黑 · 无衬线"
        case .darkSerif: "墨黑 · 衬线"
        }
    }
    var isDark: Bool { self == .darkSans || self == .darkSerif }
    var isSerif: Bool { self == .lightSerif || self == .darkSerif }
    var fontFamily: String { isSerif ? "Georgia, 'Songti SC', 'STSong', serif" : "-apple-system, 'PingFang SC', sans-serif" }
    var css: String {
        let colors = isDark
            ? "body { color:#e9edf2; background:#1d232d; } h1,h2 { border-color:#485363; } th,code,pre { background:#293442; } td,th { border-color:#485363; } a { color:#8ab4f8; } blockquote { color:#b8c2cf; border-color:#7d8998; }"
            : "body { color:#202124; background:#fff; } h1,h2 { border-color:#d9dde3; }"
        return colors + " body { font-family: \(fontFamily); }"
    }

    static func migrated(_ value: String?) -> Self {
        if let value, let style = Self(rawValue: value) { return style }
        switch value {
        case "book", "paper": return .lightSerif
        case "night": return .darkSans
        default: return .lightSans
        }
    }
}

enum PDFMarginSize: String, CaseIterable {
    case small, medium, large
    var millimeters: CGFloat { switch self { case .small: 12; case .medium: 20; case .large: 28 } }
    var points: CGFloat { millimeters * 72 / 25.4 }
    var name: String { "\(self == .small ? "小" : self == .medium ? "中" : "大") · \(Int(millimeters)) mm" }
}

enum PDFPaperSize: String, CaseIterable {
    case a4, letter
    var name: String { self == .a4 ? "A4 · 210 × 297 mm" : "Letter · 8.5 × 11 英寸" }
    var points: CGSize { self == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792) }
}

enum PDFOrientation: String, CaseIterable {
    case portrait, landscape
    var name: String { self == .portrait ? "纵向" : "横向（适合宽表格）" }
}

enum PDFLineSpacing: String, CaseIterable {
    case compact, normal, relaxed
    var name: String { switch self { case .compact: "紧凑 · 1.4"; case .normal: "标准 · 1.65"; case .relaxed: "宽松 · 1.9" } }
    var multiplier: CGFloat { switch self { case .compact: 1.4; case .normal: 1.65; case .relaxed: 1.9 } }
}

enum PDFDecorationSize: String, CaseIterable {
    case small, medium, large
    var points: CGFloat { switch self { case .small: 8; case .medium: 10; case .large: 12 } }
    var name: String { "\(self == .small ? "小" : self == .medium ? "中" : "大") · \(Int(points)) pt" }
}

struct MarkdownAppearance {
    let fontSize: CGFloat
    let additionalCSS: String
    static let preview = MarkdownAppearance(fontSize: 16, additionalCSS: "")
}

struct PDFExportOptions: Equatable {
    var style: PDFExportStyle = .lightSans
    var fontSize: CGFloat = 16
    var titleFontSize: CGFloat = 32
    var topMargin: PDFMarginSize = .medium
    var bottomMargin: PDFMarginSize = .medium
    var horizontalMargin: PDFMarginSize = .medium
    var paperSize: PDFPaperSize = .a4
    var orientation: PDFOrientation = .portrait
    var lineSpacing: PDFLineSpacing = .normal
    var showsHeader = false
    var showsPageNumbers = true
    var decorationSize: PDFDecorationSize = .medium

    static let `default` = PDFExportOptions()
    var normalizedFontSize: CGFloat { fontSize.isFinite ? min(32, max(8, fontSize.rounded())) : 16 }
    var normalizedTitleFontSize: CGFloat { titleFontSize.isFinite ? min(72, max(16, titleFontSize.rounded())) : 32 }

    var appearance: MarkdownAppearance {
        let layout = PDFPageLayout.Geometry(options: self)
        let css = """
        \(style.css)
        :root { color-scheme: light; }
        html,body { margin:0; padding:0; max-width:none; width:100%; box-sizing:border-box; }
        body { display:flow-root; font-size:\(Int(normalizedFontSize))pt; line-height:\(lineSpacing.multiplier); -webkit-print-color-adjust:exact; print-color-adjust:exact; }
        h1 { font-size:\(Int(normalizedTitleFontSize))pt; }
        #content { overflow-wrap:anywhere; }
        #content > :first-child { margin-top:0; }
        pre { white-space:pre-wrap; overflow:visible; overflow-wrap:anywhere; }
        table { table-layout:fixed; }
        td,th { overflow-wrap:anywhere; }
        img { max-height:\(layout.contentHeight)px; object-fit:contain; }
        """
        return MarkdownAppearance(fontSize: normalizedFontSize, additionalCSS: css)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        var options = Self()
        options.style = .migrated(defaults.string(forKey: "pdf.style"))
        options.fontSize = CGFloat(defaults.object(forKey: "pdf.fontSize") as? Double ?? 16)
        // Before v1.6, H1 was always twice the body size. Preserve that look
        // until the user explicitly chooses an independent title size.
        options.titleFontSize = CGFloat(defaults.object(forKey: "pdf.titleFontSize") as? Double ?? Double(options.normalizedFontSize * 2))
        options.fontSize = options.normalizedFontSize
        options.titleFontSize = options.normalizedTitleFontSize
        options.topMargin = defaults.string(forKey: "pdf.topMargin").flatMap(PDFMarginSize.init(rawValue:)) ?? .medium
        options.bottomMargin = defaults.string(forKey: "pdf.bottomMargin").flatMap(PDFMarginSize.init(rawValue:)) ?? .medium
        options.horizontalMargin = defaults.string(forKey: "pdf.horizontalMargin").flatMap(PDFMarginSize.init(rawValue:)) ?? .medium
        options.paperSize = defaults.string(forKey: "pdf.paperSize").flatMap(PDFPaperSize.init(rawValue:)) ?? .a4
        options.orientation = defaults.string(forKey: "pdf.orientation").flatMap(PDFOrientation.init(rawValue:)) ?? .portrait
        options.lineSpacing = defaults.string(forKey: "pdf.lineSpacing").flatMap(PDFLineSpacing.init(rawValue:)) ?? .normal
        options.decorationSize = defaults.string(forKey: "pdf.decorationSize").flatMap(PDFDecorationSize.init(rawValue:)) ?? .medium
        options.showsHeader = defaults.object(forKey: "pdf.showsHeader") as? Bool ?? false
        options.showsPageNumbers = defaults.object(forKey: "pdf.showsPageNumbers") as? Bool ?? true
        return options
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: "pdf.style")
        defaults.set(Double(normalizedFontSize), forKey: "pdf.fontSize")
        defaults.set(Double(normalizedTitleFontSize), forKey: "pdf.titleFontSize")
        defaults.set(topMargin.rawValue, forKey: "pdf.topMargin")
        defaults.set(bottomMargin.rawValue, forKey: "pdf.bottomMargin")
        defaults.set(horizontalMargin.rawValue, forKey: "pdf.horizontalMargin")
        defaults.set(paperSize.rawValue, forKey: "pdf.paperSize")
        defaults.set(orientation.rawValue, forKey: "pdf.orientation")
        defaults.set(lineSpacing.rawValue, forKey: "pdf.lineSpacing")
        defaults.set(decorationSize.rawValue, forKey: "pdf.decorationSize")
        defaults.set(showsHeader, forKey: "pdf.showsHeader")
        defaults.set(showsPageNumbers, forKey: "pdf.showsPageNumbers")
    }
}
