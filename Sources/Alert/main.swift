import AppKit
import Foundation

switch CommandLine.arguments.dropFirst().first ?? "help" {
case "live", "watch":
    runLiveWithWarningDisplay()
case "sound-test":
    runSoundTest(soundType: CommandLine.arguments.dropFirst(2).first)
default:
    printUsage()
}

@MainActor
private func runLiveWithWarningDisplay() -> Never {
    let app = NSApplication.shared
    let config: Config

    do {
        config = try performStartupStep("config.json 설정 및 로컬 저장 폴더 점검") {
            let config = try Config.load()
            try config.validateForLive()
            return config
        }
        try performStartupStep("인터넷 연결 점검") {
            try SystemPreflight.validateInternetConnection()
        }
        try performStartupStep("오디오 출력 장치 점검") {
            try SystemPreflight.validateAudioOutput()
        }
    } catch {
        showStartupError(error)
        exit(1)
    }

    let stopSignal = StopSignal()
    let warning = WarningDisplay(
        text: config.warningText,
        windowLevel: config.warningWindowLevel,
        opacity: config.warningWindowOpacity,
        killSwitchKeyCodes: config.killSwitchKeyCodes,
        stopSignal: stopSignal
    )
    let globalKillSwitch = GlobalKillSwitch(stopSignal: stopSignal, keyCodes: config.killSwitchKeyCodes)

    DispatchQueue.global(qos: .userInitiated).async {
        do {
            try runLive(config: config, stopSignal: stopSignal) {
                DispatchQueue.main.async {
                    TerminalMinimizer.minimizeLaunchingTerminal()
                    warning.show()
                    globalKillSwitch.enable()
                }
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            DispatchQueue.main.async {
                showStartupError(error)
            }
            return
        }

        DispatchQueue.main.async {
            app.terminate(nil)
        }
    }

    app.run()
    exit(0)
}

private func runLive(config: Config, stopSignal: StopSignal, onLiveReady: @escaping () -> Void) throws {
    if stopSignal.isSet {
        return
    }

    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let sessionName = timestampedFilename().replacingOccurrences(of: ".jpg", with: "")
    let recordingURL = config.recordingDirectoryURL.appendingPathComponent(sessionName)

    let activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated],
        reason: "Alert live mode"
    )
    defer {
        ProcessInfo.processInfo.endActivity(activity)
    }

    let caffeinate = CaffeinateGuard()
    if config.preventSleep {
        caffeinate.start()
    }
    defer {
        caffeinate.stop()
    }

    let alarm = try performStartupStep("감시 세션 및 경보음 파일 준비") {
        let alarm = AlarmPlayer(
            volume: config.alarmVolume,
            playbackGain: config.alarmPlaybackGain,
            sound: config.selectedAlarmSound,
            lowHz: config.alarmSirenLowHz,
            highHz: config.alarmSirenHighHz,
            sweepHz: config.alarmSirenSweepHz,
            pulseHz: config.alarmSirenPulseHz
        )
        try alarm.prepare()
        return alarm
    }
    defer {
        alarm.cleanup()
    }

    let camera = try performStartupStep("카메라 시작 및 첫 프레임 수신 대기") {
        let camera = CameraSnapper()
        try camera.start()
        _ = try camera.snapshotJPEG()
        return camera
    }
    defer {
        camera.stop()
    }
    printStartup("카메라 프레임 수신 확인 완료")

    printStartup("로컬 JPEG 녹화 시작 중: \(recordingURL.path)")
    let recorder = LocalFrameRecorder(
        camera: camera,
        directory: recordingURL,
        fps: config.localRecordFPS
    )
    try recorder.start()
    printStartup("로컬 JPEG 녹화 시작 완료")
    defer {
        recorder.stop()
    }

    if stopSignal.isSet {
        return
    }

    let server = try performStartupStep("MacBook 내부 영상 서버 시작 중 (포트 \(config.livePort))") {
        let server = try LiveServer(
            port: config.livePort,
            token: token,
            snapshotFPS: config.liveSnapshotFPS,
            camera: camera,
            alarm: alarm
        )
        try server.start()
        return server
    }
    printStartup("내부 영상 서버 준비 완료")
    defer {
        server.stop()
    }

    if stopSignal.isSet {
        return
    }

    let tunnel = NgrokTunnel()
    let publicURL = try performStartupStep("ngrok 공개 링크 요청 및 응답 대기 중 (최대 12초)") {
        try tunnel.start(port: config.livePort)
    }
    defer {
        tunnel.stop()
    }

    if stopSignal.isSet {
        return
    }

    let liveURL = "\(publicURL)/watch?token=\(token)"
    try performStartupStep("알림 웹훅 전송 및 HTTP 응답 대기 중") {
        try Notifier(config: config).sendLiveURL(liveURL, seconds: config.liveMaxSeconds)
    }
    printStartup("알림 웹훅 전송 성공. CCTV 전체 화면으로 전환합니다.")
    onLiveReady()

    print("live mode on")
    print("url: \(liveURL)")
    print("local recording: \(recordingURL.path)")
    print("auto stop after \(Int(config.liveMaxSeconds)) seconds. press a configured kill-switch key or Ctrl-C to stop.")

    let deadline = Date().addingTimeInterval(config.liveMaxSeconds)
    while Date() < deadline && !stopSignal.isSet {
        Thread.sleep(forTimeInterval: 0.5)
    }

    print("live mode finished")
}

func printStartup(_ message: String) {
    print("[startup] \(message)")
}

private func performStartupStep<T>(_ message: String, _ operation: () throws -> T) throws -> T {
    let spinner = StartupSpinner(message: message)

    do {
        let result = try operation()
        spinner.succeed()
        return result
    } catch {
        spinner.fail()
        throw error
    }
}

private func runSoundTest(soundType: String?) {
    do {
        let config = try Config.load()
        try SystemPreflight.validateAudioOutput()
        let requestedSoundType = soundType.flatMap(Int.init)
        let sound = requestedSoundType.flatMap(AlarmSound.init(soundType:)) ?? config.selectedAlarmSound

        guard soundType == nil || (requestedSoundType != nil && AlarmSound(soundType: requestedSoundType!) != nil) else {
            throw AppError.message("sound-test 타입은 1, 2, 3, 4, 5 중 하나여야 합니다.")
        }

        let alarm = AlarmPlayer(
            volume: config.alarmVolume,
            playbackGain: config.alarmPlaybackGain,
            setSystemVolume: false,
            sound: sound,
            lowHz: config.alarmSirenLowHz,
            highHz: config.alarmSirenHighHz,
            sweepHz: config.alarmSirenSweepHz,
            pulseHz: config.alarmSirenPulseHz
        )
        defer {
            alarm.cleanup()
        }

        try alarm.prepare()
        print("testing \(sound.rawValue) for 10 seconds")
        alarm.start()
        Thread.sleep(forTimeInterval: 10)
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
}

@MainActor
private func showStartupError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "감시모드를 시작할 수 없습니다"
    alert.informativeText = String(describing: error)
    alert.addButton(withTitle: "확인")
    alert.runModal()
    NSApp.terminate(nil)
}

private func timestampedFilename() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return "\(formatter.string(from: Date())).jpg"
}

private func printUsage() {
    print("""
    usage:
      swift run alert watch         실시간 카메라, 로컬 저장, 화면 경고, 모바일 버튼 경보 시작
      swift run alert live          watch와 동일
      swift run alert sound-test    config.json의 경보음을 10초간 재생
      swift run alert sound-test 2  2번 경보음을 10초간 재생
    """)
}
