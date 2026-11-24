import AVFoundation
import SwiftUI

/// Plain live viewfinder. Deliberately shows the scene ungraded: the look is only revealed after capture.
/// Converts viewfinder points to the camera's device coordinates (for markers dragged in SwiftUI).
final class PreviewPoints {
    fileprivate weak var view: PreviewView?
    func devicePoint(for layerPoint: CGPoint) -> CGPoint? {
        view?.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var points: PreviewPoints? = nil
    var onTap: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void
    var onDoubleTap: () -> Void = {}
    var onLongPress: (_ layerPoint: CGPoint, _ devicePoint: CGPoint) -> Void = { _, _ in }
    /// Two fingers tapped at once (their midpoint): split focus and exposure.
    var onTwoFingerTap: (_ layerPoint: CGPoint) -> Void = { _ in }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.onTap = onTap
        v.onDoubleTap = onDoubleTap
        v.onLongPress = onLongPress
        v.onTwoFingerTap = onTwoFingerTap
        points?.view = v
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        v.onTap = onTap; v.onDoubleTap = onDoubleTap; v.onLongPress = onLongPress; v.onTwoFingerTap = onTwoFingerTap
        points?.view = v
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onDoubleTap: (() -> Void)?
    var onLongPress: ((CGPoint, CGPoint) -> Void)?
    var onTwoFingerTap: ((CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        // The video layer draws past its bounds; keep it inside the viewfinder so the aspect mask covers it.
        clipsToBounds = true
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        single.require(toFail: double)
        let two = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        two.numberOfTouchesRequired = 2
        single.require(toFail: two)
        addGestureRecognizer(double)
        addGestureRecognizer(single)
        addGestureRecognizer(two)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.5
        addGestureRecognizer(hold)
    }

    @objc private func doubleTapped() { onDoubleTap?() }
    @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) { onTwoFingerTap?(g.location(in: self)) }

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
