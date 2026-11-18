import AVFoundation
import SwiftUI

/// Pinch and double-tap zoom for a photo. When zoomed, panning moves around the photo instead of paging.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage?
    @Binding var zoomed: Bool

    func makeUIView(context: Context) -> ZoomScrollView {
        let v = ZoomScrollView()
        v.onZoomChange = { z in if zoomed != z { zoomed = z } }
        return v
    }

    func updateUIView(_ v: ZoomScrollView, context: Context) {
        v.onZoomChange = { z in if zoomed != z { zoomed = z } }
        if v.imageView.image !== image { v.setImage(image) }
    }

    final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
        let imageView = UIImageView()
        var onZoomChange: ((Bool) -> Void)?
        private var lastBounds: CGSize = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 5
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            decelerationRate = .fast
            imageView.contentMode = .scaleAspectFit
            addSubview(imageView)
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            double.numberOfTapsRequired = 2
            addGestureRecognizer(double)
        }
        required init?(coder: NSCoder) { fatalError() }

        func setImage(_ image: UIImage?) {
            imageView.image = image
            zoomScale = 1
            lastBounds = .zero
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard zoomScale <= 1.001, bounds.size != lastBounds, let size = imageView.image?.size, size.width > 0 else { return }
            lastBounds = bounds.size
            let fitted = AVMakeRect(aspectRatio: size, insideRect: CGRect(origin: .zero, size: bounds.size)).size
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            center()
        }

        private func center() {
            let x = max(0, (bounds.width - contentSize.width) / 2)
            let y = max(0, (bounds.height - contentSize.height) / 2)
            contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center()
            onZoomChange?(zoomScale > 1.01)
        }

        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            if zoomScale > 1.01 {
                setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let w = bounds.width / 2.5, h = bounds.height / 2.5
                zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}
