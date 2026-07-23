import Foundation

final class CaffeinateGuard {
    private var process: Process?

    func start() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/caffeinate") else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = [
            "-d",
            "-i",
            "-m",
            "-s",
            "-u",
            "-w",
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            self.process = process
        } catch {
            fputs("caffeinate error: \(error)\n", stderr)
        }
    }

    func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}
