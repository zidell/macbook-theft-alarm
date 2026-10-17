import CoreLocation
import Foundation

// 터미널에서 실행된 일반 실행 파일은 macOS가 위치 권한 창을 띄우지 않고 바로 거부합니다.
// 그래서 위치만 별도 .app 번들(watch.sh가 조립)로 `open` 실행해 권한을 받고,
// 결과를 JSON 파일로 남겨 감시 프로세스가 읽게 합니다.
// usage: alert-location <output-json-path> <parent-pid>

final class LocationWriter: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let outputURL: URL
    private var latest: CLLocation?

    init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        write()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        latest = location
        write()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        write()
    }

    private func statusName() -> String {
        guard CLLocationManager.locationServicesEnabled() else {
            return "services_off"
        }

        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "unknown"
        }
    }

    private func write() {
        var payload: [String: Any] = ["status": statusName()]
        if let latest {
            payload["lat"] = latest.coordinate.latitude
            payload["lon"] = latest.coordinate.longitude
            payload["accuracy"] = Int(latest.horizontalAccuracy)
            payload["timestamp"] = latest.timestamp.timeIntervalSince1970
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        try? data.write(to: outputURL, options: .atomic)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let parentPID = pid_t(arguments[2]) else {
    fputs("usage: alert-location <output-json-path> <parent-pid>\n", stderr)
    exit(2)
}

let writer = LocationWriter(outputURL: URL(fileURLWithPath: arguments[1]))

// 감시 프로세스가 끝나면 함께 종료합니다.
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if kill(parentPID, 0) != 0 && errno == ESRCH {
        exit(0)
    }
}

RunLoop.main.run()
