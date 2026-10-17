import Foundation

/// 위치 권한은 터미널에서 실행된 이 프로세스로는 받을 수 없어서,
/// watch.sh가 조립한 위치 전용 앱(ALERT_LOCATION_APP)을 띄우고 그 앱이 남기는 JSON을 읽습니다.
final class LocationProvider: @unchecked Sendable {
    private let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macbook-theft-alarm-location-\(getpid()).json")
    private var helperLaunched = false

    /// 위치는 감시 기능의 필수 조건이 아니므로 실패해도 시작을 막지 않습니다.
    func start() {
        try? FileManager.default.removeItem(at: outputURL)

        guard let appPath = ProcessInfo.processInfo.environment["ALERT_LOCATION_APP"],
              FileManager.default.fileExists(atPath: appPath) else {
            return
        }

        do {
            _ = try runProcess("/usr/bin/open", arguments: [
                "-g", "-n", appPath,
                "--args", outputURL.path, String(getpid())
            ])
            helperLaunched = true
        } catch {
            fputs("위치 앱 실행 실패: \(error)\n", stderr)
        }
    }

    /// 위치 앱은 이 프로세스가 끝나면 스스로 종료합니다.
    func stop() {
        try? FileManager.default.removeItem(at: outputURL)
    }

    func latestJSON() -> String {
        guard helperLaunched else {
            return #"{"available":false,"reason":"helper_missing"}"#
        }

        guard let data = try? Data(contentsOf: outputURL),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return #"{"available":false,"reason":"starting"}"#
        }

        let status = payload["status"] as? String ?? "unknown"
        guard let lat = payload["lat"] as? Double,
              let lon = payload["lon"] as? Double,
              let timestamp = payload["timestamp"] as? Double else {
            return #"{"available":false,"reason":"\#(status)"}"#
        }

        let accuracy = payload["accuracy"] as? Int ?? 0
        let age = max(0, Int(Date().timeIntervalSince1970 - timestamp))
        return """
        {"available":true,"reason":"\(status)","lat":\(lat),"lon":\(lon),"accuracy":\(accuracy),"age":\(age)}
        """
    }
}
