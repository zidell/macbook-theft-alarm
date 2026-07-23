import Foundation

final class StartupSpinner: @unchecked Sendable {
    private let message: String
    private let lock = NSLock()
    private var isActive = true

    init(message: String) {
        self.message = message

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }

            let frames = ["\\", "|", "/", "-"]
            var index = 0

            while true {
                self.lock.lock()
                let isActive = self.isActive

                guard isActive else {
                    self.lock.unlock()
                    return
                }

                Self.write("\r[startup] \(self.message) \(frames[index])")
                self.lock.unlock()
                index = (index + 1) % frames.count
                Thread.sleep(forTimeInterval: 0.12)
            }
        }
    }

    func succeed() {
        finish("완료")
    }

    func fail() {
        finish("실패")
    }

    private var active: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return isActive
    }

    private func finish(_ result: String) {
        lock.lock()
        isActive = false
        Self.write("\r[startup] \(message) \(result)\n")
        lock.unlock()
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}
