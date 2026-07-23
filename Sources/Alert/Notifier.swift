import Foundation

final class Notifier {
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func sendLiveURL(_ url: String, seconds: Double) throws {
        let minutes = Int(ceil(seconds / 60.0))
        let message = "MacBook live camera is on: \(url)\nexpires in about \(minutes) min"
        let webhookURL = config.notificationWebhookURL

        if webhookURL.lowercased().contains("hooks.slack.com/services/") {
            try sendSlack(url, minutes: minutes, webhookURL: webhookURL)
        } else if webhookURL.lowercased().contains("api.telegram.org/bot") {
            try sendTelegram(message, webhookURL: webhookURL)
        } else if webhookURL.lowercased().contains("discord.com/api/webhooks/") || webhookURL.lowercased().contains("discordapp.com/api/webhooks/") {
            try sendDiscord(message, webhookURL: webhookURL)
        } else {
            try sendGeneric(message, url: url, seconds: seconds, webhookURL: webhookURL)
        }
    }

    private func sendSlack(_ url: String, minutes: Int, webhookURL: String) throws {
        let payload: [String: Any] = [
            "text": "MacBook live camera is on: \(url)",
            "blocks": [
                [
                    "type": "section",
                    "text": [
                        "type": "mrkdwn",
                        "text": "*MacBook live camera is on*\n<\(url)|Open live view>\nexpires in about \(minutes) min"
                    ]
                ]
            ]
        ]

        try postJSON(payload, to: webhookURL)
    }

    private func sendTelegram(_ message: String, webhookURL: String) throws {
        _ = try runProcess(
            "/usr/bin/curl",
            arguments: [
                "-sS", "--fail", "-X", "POST",
                "--data-urlencode", "chat_id=\(config.notificationRecipient)",
                "--data-urlencode", "text=\(message)",
                webhookURL
            ]
        )
    }

    private func sendDiscord(_ message: String, webhookURL: String) throws {
        try postJSON(["content": message], to: webhookURL)
    }

    private func sendGeneric(_ message: String, url: String, seconds: Double, webhookURL: String) throws {
        try postJSON([
            "text": message,
            "url": url,
            "expires_in_seconds": Int(seconds)
        ], to: webhookURL)
    }

    private func postJSON(_ payload: [String: Any], to webhookURL: String) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AppError.message("알림 JSON 생성 실패")
        }

        _ = try runProcess(
            "/usr/bin/curl",
            arguments: [
                "-sS",
                "--fail",
                "-X", "POST",
                "-H", "Content-type: application/json",
                "--data", json,
                webhookURL
            ]
        )
    }
}

@discardableResult
func runProcess(_ executable: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw AppError.message("명령 실패: \(executable)\n\(stderr)")
    }

    return stdout
}
