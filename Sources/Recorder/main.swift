import AppKit

if let i = CommandLine.arguments.firstIndex(of: "--smoke-test") {
    let args = Array(CommandLine.arguments.dropFirst(i + 1))
    guard args.count == 2, let seconds = Double(args[0]) else {
        FileHandle.standardError.write("usage: Recorder --smoke-test <seconds> <out.mov|out.m4a>\n".data(using: .utf8)!)
        exit(2)
    }
    _ = NSApplication.shared  // ScreenCaptureKit needs a window server connection
    Task { exit(await SmokeTest.run(seconds: seconds, out: URL(fileURLWithPath: args[1]))) }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
