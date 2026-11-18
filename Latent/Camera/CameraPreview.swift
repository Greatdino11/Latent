import AVFoundation
import SwiftUI

/// Plain live viewfinder. Deliberately shows the scene ungraded: the look is only revealed after capture.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTap: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    var onDoubleTap: () -> Void = {}

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onTap = onTap
        v.onDoubleTap = onDoubleTap
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) { v.onTap = onTap; v.onDoubleTap = onDoubleTap }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        single.require(toFail: double)
        addGestureRecognizer(double)
        addGestureRecognizer(single)
    }

    @objc private func doubleTapped() { onDoubleTap?() }
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
