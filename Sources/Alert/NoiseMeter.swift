@preconcurrency import AVFoundation
import Foundation

/// 휴대폰 페이지에 주변 소음 크기를 보여주기 위한 마이크 입력 레벨 측정기입니다.
/// 감시 기능의 필수 조건이 아니므로 권한이 없거나 마이크가 없어도 시작을 막지 않습니다.
final class NoiseMeter: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var status = "starting"
    private var levelDB: Double = -160

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if granted {
                    self.startEngine()
                } else {
                    self.setStatus("denied")
                }
            }
        default:
            setStatus("denied")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func latest() -> (status: String, db: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (status, levelDB)
    }

    private func setStatus(_ value: String) {
        lock.lock()
        status = value
        lock.unlock()
    }

    private func startEngine() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            setStatus("unavailable")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                return
            }

            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) {
                sum += samples[index] * samples[index]
            }
            let rms = sqrt(sum / Float(buffer.frameLength))
            let db = rms > 0 ? Double(20 * log10(rms)) : -160

            self.lock.lock()
            self.levelDB = db
            self.lock.unlock()
        }

        do {
            try engine.start()
            setStatus("ok")
        } catch {
            input.removeTap(onBus: 0)
            setStatus("unavailable")
            fputs("마이크 시작 실패: \(error)\n", stderr)
        }
    }
}
