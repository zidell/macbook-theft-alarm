import Foundation

enum AlarmSound: String, CaseIterable {
    case siren
    case urgentBeep = "urgent_beep"
    case evacuationBeep = "evacuation_beep"
    case industrialPulse = "industrial_pulse"
    case machineHorn = "machine_horn"

    init?(soundType: Int) {
        switch soundType {
        case 1:
            self = .siren
        case 2:
            self = .urgentBeep
        case 3:
            self = .evacuationBeep
        case 4:
            self = .industrialPulse
        case 5:
            self = .machineHorn
        default:
            return nil
        }
    }
}

struct Config: Decodable {
    var alarmVolume: Int
    var alarmPlaybackGain: Double
    var alarmSoundType: Int
    var alarmSirenLowHz: Double
    var alarmSirenHighHz: Double
    var alarmSirenSweepHz: Double
    var alarmSirenPulseHz: Double
    var warningText: String
    var warningWindowLevel: String
    var warningWindowOpacity: Double
    var killSwitchKeys: [String]
    var preventSleep: Bool
    var livePort: Int
    var liveMaxSeconds: Double
    var liveSnapshotFPS: Double
    var localRecordFPS: Double
    var recordingDir: String
    var notificationWebhookURL: String
    var notificationRecipient: String

    enum CodingKeys: String, CodingKey {
        case alarmVolume = "alarm_volume"
        case alarmPlaybackGain = "alarm_playback_gain"
        case alarmSoundType = "alarm_sound_type"
        case alarmSirenLowHz = "alarm_siren_low_hz"
        case alarmSirenHighHz = "alarm_siren_high_hz"
        case alarmSirenSweepHz = "alarm_siren_sweep_hz"
        case alarmSirenPulseHz = "alarm_siren_pulse_hz"
        case warningText = "warning_text"
        case warningWindowLevel = "warning_window_level"
        case warningWindowOpacity = "warning_window_opacity"
        case killSwitchKeys = "kill_switch_keys"
        case preventSleep = "prevent_sleep"
        case livePort = "live_port"
        case liveMaxSeconds = "live_max_seconds"
        case liveSnapshotFPS = "live_snapshot_fps"
        case localRecordFPS = "local_record_fps"
        case recordingDir = "recording_dir"
        case notificationWebhookURL = "notification_webhook_url"
        case notificationRecipient = "notification_recipient"
    }

    static func load(from path: String = "config.json") throws -> Config {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    var recordingDirectoryURL: URL {
        URL(fileURLWithPath: NSString(string: recordingDir).expandingTildeInPath)
    }

    func validateForLive() throws {
        try validateNotification()
        try validateRecordingDirectory()

        if livePort < 1024 || livePort > 65535 {
            throw AppError.message("live_port는 1024~65535 사이여야 합니다.")
        }

        if liveMaxSeconds <= 0 {
            throw AppError.message("live_max_seconds는 0보다 커야 합니다.")
        }

        if liveSnapshotFPS <= 0 || localRecordFPS <= 0 {
            throw AppError.message("live_snapshot_fps와 local_record_fps는 0보다 커야 합니다.")
        }

        if alarmVolume < 0 || alarmVolume > 100 {
            throw AppError.message("alarm_volume은 0~100 사이여야 합니다.")
        }

        if alarmPlaybackGain <= 0 || alarmPlaybackGain > 10 {
            throw AppError.message("alarm_playback_gain은 0보다 크고 10 이하여야 합니다.")
        }

        guard AlarmSound(soundType: alarmSoundType) != nil else {
            throw AppError.message("alarm_sound_type은 1, 2, 3, 4, 5 중 하나여야 합니다.")
        }

        if alarmSirenLowHz <= 0 || alarmSirenHighHz <= alarmSirenLowHz {
            throw AppError.message("alarm_siren_low_hz/high_hz 설정이 잘못되었습니다.")
        }

        if alarmSirenSweepHz <= 0 || alarmSirenPulseHz <= 0 {
            throw AppError.message("alarm_siren_sweep_hz와 alarm_siren_pulse_hz는 0보다 커야 합니다.")
        }

        if warningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.message("warning_text는 비워둘 수 없습니다.")
        }

        if killSwitchKeyCodes.isEmpty {
            throw AppError.message("kill_switch_keys에는 c, enter, escape, space, q 중 하나 이상이 필요합니다.")
        }

        let allowedWindowLevels = ["normal", "floating", "screenSaver"]
        if !allowedWindowLevels.contains(warningWindowLevel) {
            throw AppError.message("warning_window_level은 normal, floating, screenSaver 중 하나여야 합니다.")
        }

        if warningWindowOpacity <= 0 || warningWindowOpacity > 1 {
            throw AppError.message("warning_window_opacity는 0보다 크고 1 이하여야 합니다.")
        }
    }

    var selectedAlarmSound: AlarmSound {
        AlarmSound(soundType: alarmSoundType) ?? .siren
    }

    private func validateRecordingDirectory() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let recordingPath = recordingDirectoryURL.path

        guard fileManager.fileExists(atPath: recordingPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.message("저장 폴더를 찾을 수 없습니다: \(recordingPath)")
        }

        guard fileManager.isWritableFile(atPath: recordingPath) else {
            throw AppError.message("저장 폴더에 쓸 수 없습니다: \(recordingPath)")
        }
    }

    private func validateNotification() throws {
        if notificationWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.message("config.json에 notification_webhook_url을 넣어야 실행할 수 있습니다.")
        }

        if notificationWebhookURL.lowercased().contains("api.telegram.org/bot"),
           notificationRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AppError.message("Telegram 알림에는 notification_recipient에 chat_id를 넣어야 합니다.")
        }
    }

    var killSwitchKeyCodes: Set<UInt16> {
        var keyCodes = Set<UInt16>()

        for key in killSwitchKeys.map({ $0.lowercased() }) {
            switch key {
            case "c":
                keyCodes.insert(8)
            case "enter", "return":
                keyCodes.formUnion([36, 76])
            case "escape", "esc":
                keyCodes.insert(53)
            case "space":
                keyCodes.insert(49)
            case "q":
                keyCodes.insert(12)
            default:
                break
            }
        }

        return keyCodes
    }
}

enum AppError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text):
            text
        }
    }
}
