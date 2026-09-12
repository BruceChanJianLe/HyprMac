import CoreGraphics

struct TiledDragTarget: Equatable {
    let windowID: CGWindowID
    let edge: BSPTargetEdge
}

struct TiledDragTargetResolver {
    static func resolve(pointer: CGPoint, draggedID: CGWindowID,
                        intendedSlots: [CGWindowID: CGRect]) -> TiledDragTarget? {
        guard pointer.x.isFinite, pointer.y.isFinite else { return nil }
        let hits = intendedSlots.filter { windowID, frame in
            guard windowID != draggedID,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else { return false }
            return pointer.x >= frame.minX && pointer.x <= frame.maxX
                && pointer.y >= frame.minY && pointer.y <= frame.maxY
        }
        guard hits.count == 1, let (windowID, frame) = hits.first else { return nil }

        let distances: [(BSPTargetEdge, CGFloat)] = [
            (.left, (pointer.x - frame.minX) / frame.width),
            (.right, (frame.maxX - pointer.x) / frame.width),
            (.top, (pointer.y - frame.minY) / frame.height),
            (.bottom, (frame.maxY - pointer.y) / frame.height)
        ]
        let edge = distances.dropFirst().reduce(distances[0]) { nearest, candidate in
            candidate.1 < nearest.1 ? candidate : nearest
        }.0
        return TiledDragTarget(windowID: windowID, edge: edge)
    }
}
