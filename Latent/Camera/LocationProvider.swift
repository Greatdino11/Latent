import CoreLocation
import ImageIO

/// Keeps a recent location while the camera is open, for GPS tags. Only runs when the user turned tagging on.
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private(set) var latest: CLLocation?
    private(set) var denied = false
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var active = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
    }

    func setActive(_ on: Bool) {
        active = on
        guard on else { manager.stopUpdatingLocation(); return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
        default: denied = true
        }
    }

    /// A fix no older than a few minutes, or nil.
    var current: CLLocation? {
        guard active, let latest, -latest.timestamp.timeIntervalSinceNow < 300 else { return nil }
        return latest
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        denied = status == .denied || status == .restricted
        if active, status == .authorizedWhenInUse || status == .authorizedAlways { manager.startUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let last = locations.last, last.horizontalAccuracy >= 0 { latest = last }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

extension CLLocation {
    /// EXIF GPS dictionary for this fix.
    var exifGPS: [String: Any] {
        let utc = TimeZone(identifier: "UTC")!
        let time = DateFormatter(); time.timeZone = utc; time.dateFormat = "HH:mm:ss.SS"
        let date = DateFormatter(); date.timeZone = utc; date.dateFormat = "yyyy:MM:dd"
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSTimeStamp as String: time.string(from: timestamp),
            kCGImagePropertyGPSDateStamp as String: date.string(from: timestamp),
            kCGImagePropertyGPSHPositioningError as String: horizontalAccuracy,
        ]
        if verticalAccuracy >= 0 {
            gps[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = altitude < 0 ? 1 : 0
        }
        return gps
    }
}
