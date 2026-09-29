import DittoKit

// Ditto for macOS.
//
// A port of Ditto, the Windows clipboard manager, keeping its behaviour, its
// options and - importantly - its database format. See mac/README.md for what
// carried over unchanged, what had to be rebuilt on macOS terms, and what is
// deliberately not here.
//
// Everything lives in the DittoKit library so that it can be unit tested; this
// file only starts it.

DittoApp.run()
