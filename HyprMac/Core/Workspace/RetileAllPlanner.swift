import CoreGraphics

struct RetileAllPlan {
    let assignments: [Int: [CGWindowID]]
    let overflow: [CGWindowID]
}

enum RetileAllPlanner {
    static func workspaceCapacity(maxDepth: Int) -> Int {
        1 << min(max(maxDepth, 0), 7)
    }

    static func shouldRemainFloating(isAutoFloat: Bool, isOnDisabledMonitor: Bool) -> Bool {
        isAutoFloat || isOnDisabledMonitor
    }

    static func eligibleWindowIDs(
        workspaceAssignments: [Int: Set<CGWindowID>],
        discoveredWindowIDs: Set<CGWindowID>,
        excludedWindowIDs: Set<CGWindowID>
    ) -> [CGWindowID] {
        let trackedWindowIDs = workspaceAssignments.values.reduce(into: Set<CGWindowID>()) {
            $0.formUnion($1)
        }
        return trackedWindowIDs
            .union(discoveredWindowIDs)
            .subtracting(excludedWindowIDs)
            .sorted()
    }

    static func pack(
        windowIDs: [CGWindowID],
        workspaceCount: Int,
        capacityForWorkspace: (Int) -> Int
    ) -> RetileAllPlan {
        var assignments: [Int: [CGWindowID]] = [:]
        var nextWindow = 0

        for workspace in 1...workspaceCount {
            let capacity = max(0, capacityForWorkspace(workspace))
            guard capacity > 0, nextWindow < windowIDs.count else { continue }
            let end = min(nextWindow + capacity, windowIDs.count)
            assignments[workspace] = Array(windowIDs[nextWindow..<end])
            nextWindow = end
        }

        return RetileAllPlan(
            assignments: assignments,
            overflow: Array(windowIDs[nextWindow...])
        )
    }

    /// Plan placement for a discovery batch without rewriting existing
    /// workspace assignments. `eligibleWorkspaces` is supplied by the caller
    /// so admission stays on the window's physical monitor.
    static func admit(
        windowIDs: [CGWindowID],
        preferredWorkspace: Int,
        eligibleWorkspaces: [Int],
        existingAssignments: [Int: Set<CGWindowID>],
        excludedWindowIDs: Set<CGWindowID>,
        capacityForWorkspace: (Int) -> Int
    ) -> RetileAllPlan {
        let incomingIDs = Array(Set(windowIDs)).sorted()
        let homes = eligibleWorkspaces.sorted()
        guard !homes.isEmpty else {
            return RetileAllPlan(assignments: [preferredWorkspace: incomingIDs], overflow: incomingIDs)
        }

        let start = homes.firstIndex(of: preferredWorkspace) ?? homes.startIndex
        let orderedHomes = Array(homes[start...]) + Array(homes[..<start])
        var remainingCapacity = Dictionary(uniqueKeysWithValues: orderedHomes.map { workspace in
            let occupied = existingAssignments[workspace, default: []]
                .subtracting(excludedWindowIDs)
                .subtracting(incomingIDs).count
            return (workspace, max(0, capacityForWorkspace(workspace) - occupied))
        })
        var assignments: [Int: [CGWindowID]] = [:]
        var overflow: [CGWindowID] = []

        for windowID in incomingIDs {
            if excludedWindowIDs.contains(windowID) {
                assignments[preferredWorkspace, default: []].append(windowID)
                continue
            }
            if let workspace = orderedHomes.first(where: { remainingCapacity[$0, default: 0] > 0 }) {
                assignments[workspace, default: []].append(windowID)
                remainingCapacity[workspace, default: 0] -= 1
            } else {
                // retain the old active-workspace membership so the existing
                // tile rejection path can route genuine overflow.
                assignments[preferredWorkspace, default: []].append(windowID)
                overflow.append(windowID)
            }
        }

        return RetileAllPlan(assignments: assignments, overflow: overflow)
    }

    /// Apply a batch plan through dispatcher-owned assignment and parking
    /// operations. Kept free of AppKit dependencies for focused tests.
    static func applyAdmission(
        _ plan: RetileAllPlan,
        isWorkspaceVisible: (Int) -> Bool,
        assign: (CGWindowID, Int) -> Void,
        park: (CGWindowID, Int) -> Void
    ) {
        for workspace in plan.assignments.keys.sorted() {
            for windowID in plan.assignments[workspace] ?? [] {
                assign(windowID, workspace)
                if !isWorkspaceVisible(workspace) {
                    park(windowID, workspace)
                }
            }
        }
    }
}
