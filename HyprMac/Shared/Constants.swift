// Cross-module shared tunables. Subsystem-local values stay in their
// own files (`TilingConfig`, file-private `enum Tuning`, etc.).

import AppKit

enum Constants {
    static let workspaceCount = 10
    static let workspaceRange = 1...workspaceCount

    // keep interactive windows above the floating border and dim panels
    static let interfaceWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
}
