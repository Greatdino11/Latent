import CoreGraphics; import ImageIO; import Foundation; import UniformTypeIdentifiers
let args = CommandLine.arguments; let out = args[1]; let files = Array(args[2...])
let cols = 5, cw = 400, ch = 600, pad = 8
let rows = (files.count + cols - 1) / cols
let W = cols * (cw + pad) + pad, H = rows * (ch + pad) + pad
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
c.setFillColor(gray: 0.15, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (i, f) in files.enumerated() {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: f) as CFURL, nil)!
  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: ch] as CFDictionary)!
  let r = i / cols, col = i % cols
  let x = pad + col * (cw + pad), y = H - (r + 1) * (ch + pad)
  let s = min(Double(cw) / Double(img.width), Double(ch) / Double(img.height))
  let w = Double(img.width) * s, h = Double(img.height) * s
  c.draw(img, in: CGRect(x: Double(x) + (Double(cw) - w)/2, y: Double(y) + (Double(ch) - h)/2, width: w, height: h))
}
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, c.makeImage()!, nil); CGImageDestinationFinalize(d)
