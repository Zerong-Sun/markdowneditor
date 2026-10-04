import Foundation
import PDFKit

guard CommandLine.arguments.count == 2,
      let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    fatalError("Usage: swift Tests/VerifyExportedPDF.swift <exported pdf-long.pdf>")
}
let text = (document.string ?? "").filter { !$0.isWhitespace }
precondition(document.pageCount > 1, "Expected multiple pages")
precondition(text.contains("BEGIN-MARKDOWNSTUDIO-PDF"), "Missing start marker")
precondition(text.contains("END-MARKDOWNSTUDIO-PDF"), "Missing end marker")
for section in 1...65 {
    precondition(text.contains("第\(section)节"), "Missing section \(section)")
}
for index in 0..<document.pageCount {
    let bounds = document.page(at: index)!.bounds(for: .mediaBox)
    precondition(abs(bounds.width - 595.28) < 1 && abs(bounds.height - 841.89) < 1, "Expected A4 page")
}
print("PDF verified: \(document.pageCount) A4 pages, 65 sections, both markers present.")
