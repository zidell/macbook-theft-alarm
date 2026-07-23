import Foundation

final class NgrokTunnel {
    private let process = Process()

    func start(port: Int) throws -> String {
        let ngrokPath = try findNgrok()
        process.executableURL = URL(fileURLWithPath: ngrokPath)
        process.arguments = [
            "http",
            "http://127.0.0.1:\(port)",
            "--log=stdout"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        return try waitForURL()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func findNgrok() throws -> String {
        var candidates = [String]()

        if let configuredPath = ProcessInfo.processInfo.environment["NGROK_PATH"],
           !configuredPath.isEmpty {
            candidates.append(configuredPath)
        }

        candidates += [
            NSString(string: "~/.local/bin/ngrok").expandingTildeInPath,
            "/opt/homebrew/bin/ngrok",
            "/usr/local/bin/ngrok",
            "/usr/bin/ngrok"
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        throw AppError.message("ngrok을 찾지 못했습니다. 터미널에서 sudo ./watch.sh를 다시 실행하세요.")
    }

    private func waitForURL() throws -> String {
        let deadline = Date().addingTimeInterval(12)

        while Date() < deadline {
            if !process.isRunning {
                let stderr = (process.standardError as? Pipe)
                    .map { String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" } ?? ""
                throw AppError.message("ngrok 실행 실패: \(stderr)")
            }

            if let url = queryNgrokAPI() {
                return url
            }

            Thread.sleep(forTimeInterval: 0.4)
        }

        throw AppError.message("ngrok 공개 URL을 12초 안에 받지 못했습니다.")
    }

    private func queryNgrokAPI() -> String? {
        guard let output = try? runProcess(
            "/usr/bin/curl",
            arguments: ["-sS", "http://127.0.0.1:4040/api/tunnels"]
        ),
        let data = output.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let tunnels = json["tunnels"] as? [[String: Any]] else {
            return nil
        }

        return tunnels
            .compactMap { $0["public_url"] as? String }
            .first { $0.hasPrefix("https://") }
    }
}
