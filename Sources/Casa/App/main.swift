import AppKit

// Stamp the clock before anything else runs. Every launch measurement is
// relative to this line, so it must be the first statement in the process.
_ = LaunchClock.processStart
LaunchClock.mark("main")

// `NSApplication.shared` is where AppKit actually initializes: it loads the
// framework's lazy machinery, connects to the window server and sets up the
// event loop. It is by far the largest fixed cost in the launch budget, so it
// is measured separately from everything we control.
let application = NSApplication.shared
LaunchClock.mark("nsapp-init")

application.setActivationPolicy(.regular)

let delegate = AppDelegate()
application.delegate = delegate
LaunchClock.mark("pre-run")

application.run()
