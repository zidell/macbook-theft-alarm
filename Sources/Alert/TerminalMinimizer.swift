import AppKit
import Foundation

enum TerminalMinimizer {
    static func minimizeLaunchingTerminal() {
        guard let terminal = NSWorkspace.shared.frontmostApplication,
              terminal.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleIdentifier = terminal.bundleIdentifier else {
            printStartup("실행 터미널을 찾지 못해 최소화를 건너뜁니다.")
            return
        }

        do {
            _ = try runProcess(
                "/usr/bin/osascript",
                arguments: ["-e", "tell application id \"\(bundleIdentifier)\" to set miniaturized of front window to true"]
            )
            printStartup("실행 터미널 최소화 완료")
        } catch {
            terminal.hide()
            printStartup("실행 터미널 최소화 권한이 없어 창을 숨겼습니다.")
        }
    }
}
