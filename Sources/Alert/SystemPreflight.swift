import CoreAudio
import Foundation
import Network

enum SystemPreflight {
    static func validateInternetConnection() throws {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "alert.network-preflight")
        let semaphore = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied {
                semaphore.signal()
            }
        }
        monitor.start(queue: queue)
        defer {
            monitor.cancel()
        }

        guard semaphore.wait(timeout: .now() + 2) == .success else {
            throw AppError.message("인터넷 연결이 필요합니다.")
        }
    }

    static func validateAudioOutput() throws {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw AppError.message("사용 가능한 스피커 또는 오디오 출력 장치를 찾을 수 없습니다.")
        }

        var isAlive: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsAlive
        let aliveStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isAlive)

        guard aliveStatus == noErr, isAlive != 0 else {
            throw AppError.message("사용 가능한 스피커 또는 오디오 출력 장치를 찾을 수 없습니다.")
        }
    }
}
