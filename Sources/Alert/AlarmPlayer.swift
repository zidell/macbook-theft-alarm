import AVFoundation
import Foundation

final class AlarmPlayer: @unchecked Sendable {
    private let volume: Int
    private let playbackGain: Double
    private let setSystemVolume: Bool
    private let sound: AlarmSound
    private let lowHz: Double
    private let highHz: Double
    private let sweepHz: Double
    private let pulseHz: Double
    private let clipSeconds = 2.4
    private let lock = NSLock()
    private var process: Process?
    private var alarmURL: URL?
    private var originalSystemVolume: Int?

    init(volume: Int, playbackGain: Double, setSystemVolume: Bool = true, sound: AlarmSound, lowHz: Double, highHz: Double, sweepHz: Double, pulseHz: Double) {
        self.volume = volume
        self.playbackGain = playbackGain
        self.setSystemVolume = setSystemVolume
        self.sound = sound
        self.lowHz = lowHz
        self.highHz = highHz
        self.sweepHz = sweepHz
        self.pulseHz = pulseHz
    }

    var isRunning: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return process?.isRunning == true
    }

    func prepare() throws {
        if alarmURL != nil {
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alert-siren-\(ProcessInfo.processInfo.processIdentifier).caf")
        try makeAlarmFile(at: url, seconds: clipSeconds)
        alarmURL = url
    }

    func start() {
        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            try prepare()
            if setSystemVolume {
                rememberCurrentSystemVolume()
                raiseSystemVolume()
            }

            guard let alarmURL else {
                throw AppError.message("경보 파일을 만들지 못했습니다.")
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-c",
                """
                trap '[[ -n "$child" ]] && kill "$child" 2>/dev/null; exit 0' TERM INT
                while true; do
                  /usr/bin/afplay -v "\(playbackGain)" "$1" &
                  child=$!
                  wait "$child"
                  child=
                done
                """,
                "alert-alarm-loop",
                alarmURL.path
            ]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()

            lock.lock()
            self.process = process
            lock.unlock()
        } catch {
            fputs("alarm error: \(error)\n", stderr)
        }
    }

    func stop() {
        lock.lock()
        let process = process
        self.process = nil
        lock.unlock()

        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    func cleanup() {
        stop()
        restoreSystemVolume()

        lock.lock()
        let alarmURL = alarmURL
        self.alarmURL = nil
        lock.unlock()

        if let alarmURL {
            try? FileManager.default.removeItem(at: alarmURL)
        }
    }

    private func makeAlarmFile(at url: URL, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)

        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let chunkFrames = AVAudioFrameCount(sampleRate)
        let totalFrames = Int(sampleRate * seconds)
        var writtenFrames = 0

        while writtenFrames < totalFrames {
            let frames = min(Int(chunkFrames), totalFrames - writtenFrames)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)

            let samples = buffer.floatChannelData![0]
            for frame in 0..<frames {
                let absoluteFrame = writtenFrames + frame
                let t = Double(absoluteFrame) / sampleRate
                let (frequency, gate) = waveform(at: t)
                let phase = 2.0 * Double.pi * frequency * t
                let horn = sin(phase)
                    + 0.42 * sin(3.0 * phase)
                    + 0.22 * sin(5.0 * phase)
                    + 0.10 * sin(7.0 * phase)
                let driven = tanh(1.6 * horn) * gate
                samples[frame] = Float(0.92 * driven)
            }

            try file.write(from: buffer)
            writtenFrames += frames
        }
    }

    private func waveform(at time: Double) -> (frequency: Double, gate: Double) {
        switch sound {
        case .siren:
            let tonePhase = (time * sweepHz).truncatingRemainder(dividingBy: 1.0)
            let targetFrequency = tonePhase < 0.5 ? highHz : lowHz
            let edgeDistance = min(abs(tonePhase - 0.5), min(tonePhase, 1.0 - tonePhase))
            let transition = min(edgeDistance / 0.08, 1.0)
            let frequency = targetFrequency * transition + ((lowHz + highHz) / 2.0) * (1.0 - transition)
            let pulse = sin(2.0 * Double.pi * pulseHz * time) > -0.15 ? 1.0 : 0.62
            return (frequency, pulse)

        case .urgentBeep:
            return (highHz, repeatingBeepGate(time: time, period: 0.62, windows: [(0.00, 0.09), (0.15, 0.24), (0.30, 0.39)]))

        case .evacuationBeep:
            let phase = time.truncatingRemainder(dividingBy: 0.60)
            let frequency = phase < 0.18 ? highHz : lowHz
            return (frequency, repeatingBeepGate(time: time, period: 0.60, windows: [(0.00, 0.18), (0.28, 0.46)]))

        case .industrialPulse:
            return (460, repeatingBeepGate(time: time, period: 0.96, windows: [(0.00, 0.16), (0.25, 0.41), (0.50, 0.66)]))

        case .machineHorn:
            let phase = time.truncatingRemainder(dividingBy: 0.72)
            let frequency: Double = phase < 0.24 ? 390 : 520
            return (frequency, repeatingBeepGate(time: time, period: 0.72, windows: [(0.00, 0.24), (0.30, 0.54)]))
        }
    }

    private func repeatingBeepGate(time: Double, period: Double, windows: [(Double, Double)]) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period)
        let fade = 0.008

        for (start, end) in windows where phase >= start && phase < end {
            let edgeDistance = min(phase - start, end - phase)
            return min(edgeDistance / fade, 1.0)
        }

        return 0
    }

    private func raiseSystemVolume() {
        do {
            _ = try runProcess(
                "/usr/bin/osascript",
                arguments: ["-e", "set volume output volume \(volume)"]
            )
        } catch {
            fputs("volume error: \(error)\n", stderr)
        }
    }

    private func rememberCurrentSystemVolume() {
        lock.lock()
        let alreadySaved = originalSystemVolume != nil
        lock.unlock()

        guard !alreadySaved,
              let output = try? runProcess("/usr/bin/osascript", arguments: ["-e", "output volume of (get volume settings)"]),
              let savedVolume = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }

        lock.lock()
        if originalSystemVolume == nil {
            originalSystemVolume = savedVolume
        }
        lock.unlock()
    }

    private func restoreSystemVolume() {
        lock.lock()
        let savedVolume = originalSystemVolume
        originalSystemVolume = nil
        lock.unlock()

        guard let savedVolume else {
            return
        }

        do {
            _ = try runProcess(
                "/usr/bin/osascript",
                arguments: ["-e", "set volume output volume \(savedVolume)"]
            )
        } catch {
            fputs("volume restore error: \(error)\n", stderr)
        }
    }
}
