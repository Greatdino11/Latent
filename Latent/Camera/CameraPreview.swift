import AVFoundation
import SwiftUI

/// Plain live viewfinder. Deliberately shows the scene ungraded: the look is only revealed after capture.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    var onDoubleTap: () -> Void = {}
    var onLongPress: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void = { _, _ in }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onTap = onTap
        v.onDoubleTap = onDoubleTap
        v.onLongPress = onLongPress
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) { v.onTap = onTap; v.onDoubleTap = onDoubleTap; v.onLongPress = onLongPress }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onLongPress: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // The video layer draws past its bounds; keep it inside the viewfinder so the aspect mask covers it.
        clipsToBounds = true
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        single.require(toFail: double)
        addGestureRecognizer(double)
        addGestureRecognizer(single)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.5
        addGestureRecognizer(hold)
    }

    @objc private func doubleTapped() { onDoubleTap?() }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: self)
        onLongPress?(p, previewLayer.captureDevicePointConverted(fromLayerPoint: p))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        onTap?(p, previewLayer.captureDevicePointConverted(fromLayerPoint: p))
    }
}
