import AppKit
import Foundation
import TranscribeCpp

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "transcribe":
    // dictate transcribe <file.wav>  — offline check of the model without the mic.
    guard args.count >= 2 else { fail("usage: dictate transcribe <file.wav>") }
    let config = Config.load()
    do {
        let pcm = try Wav.readMono16k(URL(fileURLWithPath: args[1]))
        var t: Transcriber? = Transcriber(config: config)
        let sem = DispatchSemaphore(value: 0)
        t!.transcribe(pcm) { result in
            switch result {
            case .success(let text): print(config.postProcess(text))
            case .failure(let e): FileHandle.standardError.write("error: \(e)\n".data(using: .utf8)!)
            }
            sem.signal()
        }
        sem.wait()
        t?.unload()  // ggml's Metal teardown asserts if a model outlives exit()
        t = nil
    } catch { fail("\(error)") }

case "fix":
    // Run dictionary + replacements on text: dictate fix "neo vim and super whisper"
    let config = Config.load()
    let input = args.count > 1 ? args[1...].joined(separator: " ") : String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print(config.postProcess(input.trimmingCharacters(in: .newlines)))
case "config":
    print(Config.path.path)
    if let data = try? JSONEncoder().encode(Config.load()), let s = String(data: data, encoding: .utf8) { print(s) }

case "mics":
    let picked = AudioDevices.selectedUID
    let def = AudioDevices.defaultInputDevice()
    for d in AudioDevices.inputDevices() {
        var marks: [String] = []
        if d == def { marks.append("default") }
        if d.uid == picked { marks.append("selected") }
        print("\(d.name)\(marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]")\n    uid: \(d.uid)")
    }

case "version":
    print("dictate 0.1.0, transcribe.cpp \(Transcribe.version())")

case "help", "-h", "--help":
    print("""
    dictate                 run the hotkey daemon
    dictate transcribe FILE transcribe a WAV file (any rate; converted to 16 kHz mono)
    dictate config          print config path and effective config
    dictate fix TEXT        apply dictionary and replacements to TEXT
    dictate mics            list input devices
    dictate version
    """)

default:
    redirectLogIfDetached()
    let config = Config.load()
    // Refuse to run twice: two event taps would both claim the hotkey.
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: "cc.stanleywang.dictate")
        .filter { $0.processIdentifier != me }
    if let other = others.first {
        log("already running as pid \(other.processIdentifier); exiting")
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = DictateApp(config: config)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

/// Finder/`open` launches send stderr to /dev/null; append to the launchd log
/// instead so every run is traceable.
func redirectLogIfDetached() {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(STDERR_FILENO, F_GETPATH, &buf) == 0, String(cString: buf) == "/dev/null" else { return }
    let env = ProcessInfo.processInfo.environment
    let base = env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
    let dir = base.appendingPathComponent("dictate")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fd = open(dir.appendingPathComponent("dictate.log").path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    dup2(fd, STDOUT_FILENO)
    dup2(fd, STDERR_FILENO)
    close(fd)
}
