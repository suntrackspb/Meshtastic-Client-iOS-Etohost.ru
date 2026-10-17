import CoreLocation

/// Пока нода подключена, держим приложение живым в фоне через геолокацию —
/// как Meshtastic-Apple (LocationsHandler + CLBackgroundActivitySession).
/// Иначе iOS усыпляет приложение и рвёт TCP к ноде и WebSocket к зеркалу.
@MainActor
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()

    private let manager = CLLocationManager()
    private var session: CLBackgroundActivitySession?
    private var active = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
    }

    func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        value ? begin() : end()
    }

    private func begin() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = false
            session = CLBackgroundActivitySession()
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    private func end() {
        manager.stopUpdatingLocation()
        session?.invalidate()
        session = nil
        if manager.authorizationStatus != .notDetermined {
            manager.allowsBackgroundLocationUpdates = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.active, self.session == nil { self.begin() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
