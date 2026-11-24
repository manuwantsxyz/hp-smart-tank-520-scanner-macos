// Renders a 1024px app icon PNG from an SF Symbol.
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: size - 200, height: size - 200)
let bg = NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.70, alpha: 1))!.draw(in: bg, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 440, weight: .regular)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "doc.viewfinder", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
