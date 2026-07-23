@preconcurrency import AVFoundation
import CoreImage
import Foundation
import AppKit

final class CameraSnapper: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "alert.camera.session")
    private let frameQueue = DispatchQueue(label: "alert.camera.frames")
    private let lock = NSLock()
    private let context = CIContext()
    private var latestPixelBuffer: CVPixelBuffer?

    func start() throws {
        try ensureCameraPermission()

        session.beginConfiguration()
        session.sessionPreset = .medium

        let device = try selectCamera()
        print("camera: \(device.localizedName)")

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AppError.message("카메라 입력을 추가할 수 없습니다.")
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(videoOutput) else {
            throw AppError.message("카메라 출력 설정에 실패했습니다.")
        }
        session.addOutput(videoOutput)
        session.commitConfiguration()

        sessionQueue.sync {
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.sync {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func capture(to url: URL) throws {
        let data = try snapshotJPEG()
        try data.write(to: url, options: .atomic)
    }

    func snapshotJPEG(timeout: TimeInterval = 3) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer: CVPixelBuffer?

        while Date() < deadline {
            lock.lock()
            buffer = latestPixelBuffer
            lock.unlock()

            if buffer != nil {
                break
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        guard let buffer else {
            throw AppError.message("카메라 프레임이 \(Int(timeout))초 안에 들어오지 않았습니다.")
        }

        let image = CIImage(cvPixelBuffer: buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.72]
        ) else {
            throw AppError.message("카메라 프레임을 JPEG로 변환하지 못했습니다.")
        }

        return data
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        lock.lock()
        latestPixelBuffer = pixelBuffer
        lock.unlock()
    }

    private func ensureCameraPermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()

            if !granted {
                openCameraPrivacySettings()
                throw AppError.message("카메라 권한이 거부되었습니다. 열린 시스템 설정에서 카메라 권한을 허용한 뒤 다시 실행하세요.")
            }
        default:
            openCameraPrivacySettings()
            throw AppError.message("카메라 권한이 없습니다. 열린 시스템 설정에서 카메라 권한을 허용한 뒤 다시 실행하세요.")
        }
    }

    private func openCameraPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func selectCamera() throws -> AVCaptureDevice {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )

        if let builtIn = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return builtIn
        }

        if let continuity = discovery.devices.first(where: { $0.deviceType == .continuityCamera }) {
            return continuity
        }

        if let fallback = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) {
            return fallback
        }

        throw AppError.message("카메라를 찾지 못했습니다.")
    }
}
