import Foundation

final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isSet: Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return stopped
    }

    func set() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
