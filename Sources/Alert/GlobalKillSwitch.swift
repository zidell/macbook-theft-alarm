import AppKit

@MainActor
final class GlobalKillSwitch {
    private let stopSignal: StopSignal
    private let keyCodes: Set<UInt16>
    private var monitor: Any?

    init(stopSignal: StopSignal, keyCodes: Set<UInt16>) {
        self.stopSignal = stopSignal
        self.keyCodes = keyCodes
    }

    func enable() {
        guard monitor == nil else {
            return
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if self.keyCodes.contains(event.keyCode) {
                self.stopSignal.set()
                print("stop requested")
            }
        }
    }
}
