import AVFoundation
import UIKit

/// A print laid out for Instagram: a 4:5 post or a 9:16 story, on the same paper as Latent's prints, so the frame
/// keeps its own shape (nothing gets cropped) and the feed sees a print, not a phone photo.
enum SocialPrint {
    enum Format: String, CaseIterable, Identifiable {
        case post, story
        var id: String { rawValue }
        var label: String { self == .post ? "Post (4:5)" : "Story (9:16)" }
        var size: CGSize { self == .post ? CGSize(width: 2160, height: 2700) : CGSize(width: 2160, height: 3840) }
    }

    /// `border`: the print's own border (white/black prints already carry their caption); otherwise a white card
    /// with the LATENT / stock caption under the photo.
    static func render(_ print: CGImage, format: Format, border: FrameStyle, stock: String) -> Data? {
        let size = format.size
        let black = border == .black
        let bordered = border == .white || border == .black
        let paper = black ? UIColor(white: 0.06, alpha: 1) : UIColor(white: 0.97, alpha: 1)
        let ink = black ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.18, alpha: 1)

        let margin = size.width * (bordered ? 0.04 : 0.08)
        let captionSpace = bordered ? 0 : size.width * 0.07
        let box = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2 - captionSpace)
        var photo = AVMakeRect(aspectRatio: CGSize(width: print.width, height: print.height), insideRect: box).integral
        photo.origin.y = ((size.height - captionSpace - photo.height) / 2).rounded()     // centred, caption below

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            paper.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: print).draw(in: photo)
            guard !bordered else { return }
            let font = UIFont.monospacedSystemFont(ofSize: size.width * 0.022, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: size.width * 0.003]
            let left = NSAttributedString(string: "LATENT", attributes: attrs)
            let right = NSAttributedString(string: stock.uppercased(), attributes: attrs)
            let y = photo.maxY + size.width * 0.03
            left.draw(at: CGPoint(x: photo.minX, y: y))
            right.draw(at: CGPoint(x: photo.maxX - right.size().width, y: y))
        }
        return image.jpegData(compressionQuality: 0.92)
    }
}
