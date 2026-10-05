import AppKit

// `ObsbotBar <command>` runs one command and exits, for scripting and testing.
// With no arguments it runs as a menu bar app.
let args = CommandLine.arguments.dropFirst()
if let command = args.first {
    let camera = Camera()
    do {
        switch command {
        case "status": break
        case "wake": try camera.wakeAndTrack()
        case "wake-only": try camera.setAwake(true)
        case "sleep": try camera.sleepAndWait()
        case "track": try camera.enableTracking()
        case "pose":
            let p = try camera.pose()
            print(String(format: "pan %.0f°  tilt %.0f°", p.pan, p.tilt))
            exit(0)
        case "aim":
            guard args.count == 3, let pan = Double(args[args.startIndex + 1]),
                  let tilt = Double(args[args.startIndex + 2]) else { exit(2) }
            try camera.aim(pan: pan, tilt: tilt)
        case "untrack": try camera.disableTracking()
        default:
            FileHandle.standardError.write("usage: ObsbotBar [status|wake|wake-only|sleep|track|untrack|pose|aim PAN TILT]\n".data(using: .utf8)!)
            exit(2)
        }
        let s = try camera.status()
        // While asleep the status block keeps reporting the pre-sleep AI mode.
        print(s.awake ? "awake, tracking: \(s.aiMode.label)" : "asleep")
    } catch {
        FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
