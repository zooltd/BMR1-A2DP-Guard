import AppKit
import Foundation
import GuardCore

// Headless CLI mode used by integration tests: `BMR1Guard --headless [seconds]`
// runs the engine without a status item and prints events to stdout.
if CommandLine.arguments.contains("--headless") {
    let secondsArg = CommandLine.arguments.last.flatMap(Double.init)
    let seconds = (secondsArg != nil && secondsArg! > 0) ? secondsArg! : 3600.0
    let engine = GuardEngine(audio: CoreAudioSystem(), store: UserDefaultsStateStore())
    engine.onStatusChanged = {}
    engine.start()
    print("BMR1Guard headless: engine started for \(seconds)s")
    setbuf(stdout, nil)
    let deadline = Date().addingTimeInterval(seconds)
    var printed = 0
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
        let events = engine.status().events
        if events.count > printed {
            for e in events.suffix(events.count - printed) {
                print("[\(ISO8601DateFormatter().string(from: e.date))] \(e.message)")
            }
            printed = events.count
        }
    }
    engine.stop()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only; also enforced by LSUIElement
app.run()
