// Steam library art for a non-Steam game, from one landscape key art image (a store's cover):
//
//   swiftc -O -o steamart tools/steamart.swift
//   steamart KEY_ART OUT_DIR "Game Name"
//
// Writes OUT_DIR/portrait.png (600x900, the library cover), wide.png (920x430), hero.png (1920x620)
// and icon.png (256x256). Key art usually carries the title somewhere in the picture, in a
// different place for every game, so the cover gets the name set in type instead.
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let image = NSImage(contentsOfFile: args[1]),
      let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: steamart KEY_ART OUT_DIR \"Game Name\"\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
let name = args[3]
let W = Double(src.width), H = Double(src.height)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func render(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    draw(ctx)
    return ctx.makeImage()!
}

// The part of the source centred on (cx, cy) with the target's aspect ratio, as large as fits.
func crop(aspect: Double, cx: Double, cy: Double) -> CGImage {
    var cw = W, ch = W / aspect
    if ch > H { ch = H; cw = H * aspect }
    let x = min(max(cx - cw / 2, 0), W - cw), y = min(max(cy - ch / 2, 0), H - ch)
    return src.cropping(to: CGRect(x: x, y: y, width: cw, height: ch))!
}

func cover(_ w: Int, _ h: Int, cx: Double = W / 2, cy: Double = H / 2) -> CGImage {
    let part = crop(aspect: Double(w) / Double(h), cx: cx, cy: cy)
    return render(w, h) { $0.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h)) }
}

func save(_ img: CGImage, _ file: String) {
    let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    try! png.write(to: out.appendingPathComponent(file))
}

save(cover(920, 430), "wide.png")
save(cover(1920, 620, cy: H * 0.4), "hero.png")
save(cover(256, 256, cy: H * 0.4), "icon.png")
save(render(600, 900) { ctx in
    ctx.draw(crop(aspect: 600.0 / 900.0, cx: W / 2, cy: H / 2), in: CGRect(x: 0, y: 0, width: 600, height: 900))
    let fade = CGGradient(colorsSpace: sRGB,
                          colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                   CGColor(red: 0, green: 0, blue: 0, alpha: 1),
                                   CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                          locations: [0, 0.6, 1])!
    // Solid behind the name, so the key art's own title (often in the lower half) doesn't show.
    ctx.drawLinearGradient(fade, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 560), options: [])
    // The name, as large as fits in two lines across the bottom.
    var size: CGFloat = 72
    var text = NSAttributedString()
    var box = CGRect.zero
    while size > 20 {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        text = NSAttributedString(string: name.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: NSColor.white, .paragraphStyle: para, .kern: size * 0.04])
        box = text.boundingRect(with: CGSize(width: 540, height: 1000), options: [.usesLineFragmentOrigin])
        if box.height <= size * 2.6 && box.width <= 540 { break }
        size -= 4
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(with: CGRect(x: 30, y: 70, width: 540, height: box.height), options: [.usesLineFragmentOrigin])
    NSGraphicsContext.restoreGraphicsState()
}, "portrait.png")
