import Foundation

final class LocalFrameRecorder: @unchecked Sendable {
    private let camera: CameraSnapper
    private let directory: URL
    private let fps: Double
    private let maxFrames: Int
    private let queue = DispatchQueue(label: "alert.local.recorder")
    private var shouldStop = false

    init(camera: CameraSnapper, directory: URL, fps: Double, retentionSeconds: Double) {
        self.camera = camera
        self.directory = directory
        self.fps = fps
        self.maxFrames = max(1, Int((fps * retentionSeconds).rounded()))
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        queue.async {
            let interval = 1.0 / self.fps
            var index = 0

            while true {
                if self.shouldStop {
                    return
                }

                do {
                    let jpeg = try self.camera.snapshotJPEG(timeout: 0.5)
                    let filename = String(format: "frame-%06d.jpg", index)
                    try jpeg.write(to: self.directory.appendingPathComponent(filename), options: .atomic)
                    self.removeFrame(atIndex: index - self.maxFrames)
                    index += 1
                } catch {
                    fputs("local record error: \(error)\n", stderr)
                }

                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    private func removeFrame(atIndex index: Int) {
        guard index >= 0 else { return }
        let filename = String(format: "frame-%06d.jpg", index)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    func stop() {
        shouldStop = true
    }
}
