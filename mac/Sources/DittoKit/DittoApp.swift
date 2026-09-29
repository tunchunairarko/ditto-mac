import Foundation
import AppKit

/// The entry point, and the only thing this library exposes.
///
/// Everything else stays internal: the executable target is a two-line
/// `main.swift`, and the tests reach in with `@testable import`. Splitting the
/// code out of the executable is what makes it testable at all - a test bundle
/// cannot link against an executable's top-level code.
public enum DittoApp {

    /// Held for the process's lifetime: `NSApplication.delegate` is a weak
    /// reference, so something else has to own the delegate.
    private static var delegate: AppDelegate?

    public static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        DittoApp.delegate = delegate
        application.delegate = delegate
        application.run()
    }
}
