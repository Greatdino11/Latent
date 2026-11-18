import CoreMotion
import Foundation

/// Reports how far the phone is tilted from the nearest level orientation, in degrees.
@Observable
final class LevelMonitor {
    private(set) var tilt: Double = 0
    @ObservationIgnored private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            let angle = atan2(g.x, -g.y)
            let quarter = Double.pi / 2
            let t = angle - (angle / quarter).rounded() * quarter
            self?.tilt = t * 180 / .pi
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}
