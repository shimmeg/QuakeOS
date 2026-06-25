// LocationService.swift — Quake4Mac
//
// Resolves the Mac's actual location (CoreLocation) for the Weather panel's "Current Location",
// reverse-geocoding to a city name. Falls back to IP geolocation (in weather.html) if denied.

import Foundation
import CoreLocation

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let mgr = CLLocationManager()
    @Published var lat: Double?
    @Published var lon: Double?
    @Published var cityName: String?

    private override init() {
        super.init()
        mgr.delegate = self
        mgr.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Ask for permission if needed and fetch the current location.
    func request() {
        switch mgr.authorizationStatus {
        case .notDetermined: mgr.requestWhenInUseAuthorization()
        case .authorizedAlways: mgr.requestLocation()   // macOS grants map to authorizedAlways; .authorizedWhenInUse is unavailable here
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways { m.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        lat = loc.coordinate.latitude; lon = loc.coordinate.longitude
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] places, _ in
            self?.cityName = places?.first?.locality ?? places?.first?.name
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { }
}
