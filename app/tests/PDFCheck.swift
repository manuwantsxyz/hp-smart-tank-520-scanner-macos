import PDFKit

enum PDFKitDoc {
    static func open(_ url: URL) -> (count: Int, sizes: [CGSize], texts: [String]) {
        guard let d = PDFDocument(url: url) else { return (0, [], []) }
        var sizes: [CGSize] = [], texts: [String] = []
        for i in 0..<d.pageCount {
            let p = d.page(at: i)!
            let b = p.bounds(for: .mediaBox)
            sizes.append(CGSize(width: b.width / 72, height: b.height / 72))
            texts.append(p.string ?? "")
        }
        return (d.pageCount, sizes, texts)
    }
}

enum PDFDocumentCheck {
    static func pageInches(_ url: URL) -> CGSize {
        guard let p = PDFDocument(url: url)?.page(at: 0) else { return .zero }
        let b = p.bounds(for: .mediaBox)
        return CGSize(width: b.width / 72, height: b.height / 72)
    }
}
