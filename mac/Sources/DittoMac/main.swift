import Foundation
import AppKit

// Ditto for macOS.
//
// A port of Ditto, the Windows clipboard manager, keeping its behaviour, its
// options and - importantly - its database format. See mac/README.md for what
// carried over unchanged, what had to be rebuilt on macOS terms, and what is
// deliberately not here.

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
