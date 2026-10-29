import CoreLocation
import MapKit
import Observation

/// The travel time to the place of a live event, for its choice on Today (R15). The app asks for the location
/// only when it shows a live event. With no location, the choice shows no travel time.
@Observable @MainActor
final class TravelTime: NSObject, CLLocationManagerDelegate {
    static let shared = TravelTime()

    /// Minutes, by place.
    private(set) var minutes: [String: Int] = [:]
    private var asked: Set<String> = []
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    /// Computes the travel time to `place` once. Before the answer to the location request, the place waits.
    func show(_ place: String) {
        guard !asked.contains(place) else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            pending.insert(place)
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            asked.insert(place)
            Task { minutes[place] = await TravelTime.eta(to: place) }
        default:
            asked.insert(place)
        }
    }

    private var pending: Set<String> = []

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let places = pending
            pending = []
            for place in places { show(place) }
        }
    }

    private static func eta(to place: String) async -> Int? {
        let search = MKLocalSearch.Request()
        search.naturalLanguageQuery = place
        guard let destination = try? await MKLocalSearch(request: search).start().mapItems.first else { return nil }
        let request = MKDirections.Request()
        request.source = .forCurrentLocation()
        request.destination = destination
        request.transportType = .any
        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
        return Int((eta.expectedTravelTime / 60).rounded())
    }
}
