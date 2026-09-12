import Cocoa

struct TiledDragEvent {
    static func point(event: NSEvent, primaryHeight: CGFloat) -> CGPoint {
        if let location = event.cgEvent?.location { return location }
        let appKitPoint = event.window?.convertPoint(toScreen: event.locationInWindow)
            ?? event.locationInWindow
        return CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)
    }

    static func release(event: NSEvent, primaryHeight: CGFloat,
                        sawDragEvent: Bool) -> TiledDragRelease {
        TiledDragRelease(pointer: point(event: event, primaryHeight: primaryHeight),
                         optionDown: event.modifierFlags.contains(.option),
                         sawDragEvent: sawDragEvent)
    }
}
