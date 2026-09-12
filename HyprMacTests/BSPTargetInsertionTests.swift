import XCTest
@testable import HyprMac

final class BSPTargetInsertionTests: XCTestCase {
    func testEveryEdgeSplitsTheRequestedTargetOnTheRequestedSide() throws {
        let expectations: [(BSPTargetEdge, [CGWindowID], SplitDirection)] = [
            (.left, [1, 2, 3], .horizontal),
            (.right, [2, 1, 3], .horizontal),
            (.top, [1, 2, 3], .vertical),
            (.bottom, [2, 1, 3], .vertical)
        ]

        for (edge, order, direction) in expectations {
            let tree = makeThreeWindowTree()
            guard let candidate = tree.candidateTree(
                draggedID: 1, targetID: 2, edge: edge, maxDepth: 3
            ) else {
                XCTFail("missing candidate for \(edge)")
                continue
            }
            XCTAssertEqual(candidate.allWindows.map(\.windowID), order, "\(edge)")
            let target = try XCTUnwrap(candidate.root.find(makeWindow(id: 2)))
            let dragged = try XCTUnwrap(candidate.root.find(makeWindow(id: 1)))
            XCTAssertTrue(target.parent === dragged.parent, "\(edge)")
            XCTAssertEqual(target.parent?.splitOverride, direction, "\(edge)")
            switch edge {
            case .left, .top: XCTAssertTrue(dragged.parent?.left === dragged, "\(edge)")
            case .right, .bottom: XCTAssertTrue(dragged.parent?.right === dragged, "\(edge)")
            }
        }
    }

    func testCandidatePromotesRootSiblingAndReacquiresTargetByID() throws {
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(makeWindow(id: 1), maxDepth: 3))
        XCTAssertTrue(tree.insert(makeWindow(id: 2), maxDepth: 3))

        let candidate = try XCTUnwrap(
            tree.candidateTree(draggedID: 1, targetID: 2, edge: .left, maxDepth: 2)
        )

        XCTAssertEqual(candidate.allWindows.map(\.windowID), [1, 2])
        XCTAssertEqual(candidate.root.splitOverride, .horizontal)
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1, 2])
        XCTAssertNil(tree.root.splitOverride)
    }

    func testCandidatePromotesNonRootSiblingAndRebuildsParentLinks() throws {
        let tree = makeBalancedFourWindowTree()
        let fingerprint = tree.structuralFingerprint()

        let candidate = try XCTUnwrap(
            tree.candidateTree(draggedID: 1, targetID: 2, edge: .bottom, maxDepth: 3)
        )

        let dragged = try XCTUnwrap(candidate.root.find(makeWindow(id: 1)))
        let target = try XCTUnwrap(candidate.root.find(makeWindow(id: 2)))
        XCTAssertTrue(dragged.parent === target.parent)
        XCTAssertTrue(target.parent?.parent === candidate.root)
        XCTAssertTrue(candidate.root.left === target.parent)
        XCTAssertEqual(target.parent?.splitOverride, .vertical)
        XCTAssertEqual(tree.structuralFingerprint(), fingerprint)
        assertParentLinks(in: candidate.root)
    }

    func testCandidatePreservesUnrelatedNodeStateAndLeavesSourceUntouched() throws {
        let tree = makeBalancedFourWindowTree()
        let sourceRoot = tree.root
        let sourceLeft = try XCTUnwrap(tree.root.left)
        let sourceRight = try XCTUnwrap(tree.root.right)
        let unrelated = try XCTUnwrap(tree.root.find(makeWindow(id: 3)))
        unrelated.savedSplitRatio = 0.67
        unrelated.savedChildWasLeft = true
        unrelated.savedSplitOverride = .vertical
        let unrelatedParent = try XCTUnwrap(unrelated.parent)
        unrelatedParent.splitRatio = 0.72
        unrelatedParent.userSetRatio = true
        unrelatedParent.splitOverride = .vertical
        unrelatedParent.pendingSplitRatio = 0.61
        unrelatedParent.pendingSplitOverride = .horizontal
        let sourceFingerprint = tree.structuralFingerprint()

        let candidateValue = tree.candidateTree(
            draggedID: 2, targetID: 4, edge: .right, maxDepth: 4
        )
        XCTAssertEqual(tree.structuralFingerprint(), sourceFingerprint)
        let candidate = try XCTUnwrap(candidateValue)
        let clonedUnrelated = try XCTUnwrap(candidate.root.find(makeWindow(id: 3)))
        let clonedParent = try XCTUnwrap(clonedUnrelated.parent)

        XCTAssertFalse(candidate.root === sourceRoot)
        XCTAssertFalse(clonedUnrelated === unrelated)
        XCTAssertFalse(clonedParent === unrelatedParent)
        XCTAssertEqual(clonedUnrelated.savedSplitRatio, 0.67)
        XCTAssertEqual(clonedUnrelated.savedChildWasLeft, true)
        XCTAssertEqual(clonedUnrelated.savedSplitOverride, .vertical)
        XCTAssertEqual(clonedParent.splitRatio, 0.72, accuracy: 0.001)
        XCTAssertTrue(clonedParent.userSetRatio)
        XCTAssertEqual(clonedParent.splitOverride, .vertical)
        XCTAssertEqual(clonedParent.pendingSplitRatio, 0.61)
        XCTAssertEqual(clonedParent.pendingSplitOverride, .horizontal)
        XCTAssertEqual(tree.allWindows.map(\.windowID), [1, 2, 3, 4])
        XCTAssertTrue(tree.root === sourceRoot)
        XCTAssertTrue(tree.root.left === sourceLeft)
        XCTAssertTrue(tree.root.right === sourceRight)
        XCTAssertTrue(tree.root.find(makeWindow(id: 3)) === unrelated)
        XCTAssertEqual(unrelatedParent.splitRatio, 0.72, accuracy: 0.001)
        XCTAssertTrue(unrelatedParent.userSetRatio)
        XCTAssertEqual(unrelatedParent.splitOverride, .vertical)
        XCTAssertEqual(unrelated.savedSplitRatio, 0.67)
        XCTAssertEqual(unrelated.savedChildWasLeft, true)
        XCTAssertEqual(unrelated.savedSplitOverride, .vertical)
    }

    func testBalancedFourWindowCandidateHasNoDuplicateOrLostMembership() throws {
        let tree = makeBalancedFourWindowTree()
        let candidate = try XCTUnwrap(
            tree.candidateTree(draggedID: 2, targetID: 4, edge: .left, maxDepth: 4)
        )
        let ids = candidate.allWindows.map(\.windowID)
        XCTAssertEqual(ids, [1, 3, 2, 4])
        XCTAssertEqual(Set(ids), Set([1, 2, 3, 4]))
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(candidate.root.find(makeWindow(id: 2))?.parent?.splitOverride, .horizontal)
    }

    func testTwoTargetInsertionsTurnBalancedTwoByTwoIntoFourColumns() throws {
        let source = makeBalancedFourWindowTree()
        let first = try XCTUnwrap(
            source.candidateTree(draggedID: 2, targetID: 1, edge: .right, maxDepth: 3)
        )
        let columns = try XCTUnwrap(
            first.candidateTree(draggedID: 4, targetID: 3, edge: .right, maxDepth: 3)
        )
        let usableFrame = CGRect(x: 0, y: 0, width: 2000, height: 800)
        let frames = columns.layout(in: usableFrame, gap: 8, padding: 8)

        XCTAssertEqual(frames.map { $0.0.windowID }, [1, 2, 3, 4])
        XCTAssertEqual(Set(frames.map { $0.0.windowID }), Set([1, 2, 3, 4]))
        for (_, frame) in frames {
            XCTAssertEqual(frame.minY, frames[0].1.minY, accuracy: 0.001)
            XCTAssertEqual(frame.height, frames[0].1.height, accuracy: 0.001)
            XCTAssertLessThan(frame.width, 1000)
            XCTAssertTrue(usableFrame.contains(frame))
        }
        for index in 1..<frames.count {
            XCTAssertGreaterThan(frames[index].1.minX, frames[index - 1].1.minX)
            XCTAssertEqual(frames[index].1.minX - frames[index - 1].1.maxX, 8, accuracy: 0.001)
        }
        for first in frames.indices {
            for second in frames.indices where second > first {
                XCTAssertFalse(frames[first].1.intersects(frames[second].1))
            }
        }
        XCTAssertEqual(source.allWindows.map(\.windowID), [1, 2, 3, 4])
    }

    func testDuplicateWindowIDsRejectWithoutMutatingSource() {
        let tree = BSPTree()
        XCTAssertTrue(tree.insert(makeWindow(id: 1), maxDepth: 3))
        XCTAssertTrue(tree.insert(makeWindow(id: 1), maxDepth: 3))
        XCTAssertTrue(tree.insert(makeWindow(id: 2), maxDepth: 3))
        let fingerprint = tree.structuralFingerprint()

        XCTAssertNil(tree.candidateTree(draggedID: 1, targetID: 2,
                                        edge: .left, maxDepth: 3))
        XCTAssertEqual(tree.structuralFingerprint(), fingerprint)
    }

    func testCandidateParentLinksRemainOwnedAfterSourceDeallocation() throws {
        weak var sourceRoot: BSPNode?
        var candidate: BSPTree?
        autoreleasepool {
            var source: BSPTree? = makeBalancedFourWindowTree()
            sourceRoot = source?.root
            candidate = source?.candidateTree(draggedID: 2, targetID: 4,
                                               edge: .right, maxDepth: 4)
            source = nil
        }

        XCTAssertNil(sourceRoot)
        let retainedCandidate = try XCTUnwrap(candidate)
        assertParentLinks(in: retainedCandidate.root)
    }

    func testCandidateRejectsDepthLimitAndInvalidMembershipWithoutMutation() {
        let tree = makeThreeWindowTree()
        let original = tree.allWindows.map(\.windowID)
        let fingerprint = tree.structuralFingerprint()

        XCTAssertNil(tree.candidateTree(draggedID: 1, targetID: 2, edge: .left, maxDepth: 1))
        XCTAssertNil(tree.candidateTree(draggedID: 99, targetID: 2, edge: .left, maxDepth: 3))
        XCTAssertNil(tree.candidateTree(draggedID: 1, targetID: 99, edge: .left, maxDepth: 3))
        XCTAssertNil(tree.candidateTree(draggedID: 1, targetID: 1, edge: .left, maxDepth: 3))
        XCTAssertEqual(tree.allWindows.map(\.windowID), original)
        XCTAssertEqual(tree.structuralFingerprint(), fingerprint)
    }

    func testParentLinksDoNotKeepDiscardedTreeAlive() {
        weak var discardedRoot: BSPNode?
        autoreleasepool {
            var tree: BSPTree? = makeThreeWindowTree()
            discardedRoot = tree?.root
            tree = nil
        }
        XCTAssertNil(discardedRoot)
    }
}

private func assertParentLinks(in node: BSPNode,
                               file: StaticString = #filePath, line: UInt = #line) {
    if let left = node.left {
        XCTAssertTrue(left.parent === node, file: file, line: line)
        assertParentLinks(in: left, file: file, line: line)
    }
    if let right = node.right {
        XCTAssertTrue(right.parent === node, file: file, line: line)
        assertParentLinks(in: right, file: file, line: line)
    }
}

private func makeThreeWindowTree() -> BSPTree {
    let tree = BSPTree()
    XCTAssertTrue(tree.insert(makeWindow(id: 1), maxDepth: 3))
    XCTAssertTrue(tree.insert(makeWindow(id: 2), maxDepth: 3))
    XCTAssertTrue(tree.insert(makeWindow(id: 3), maxDepth: 3))
    return tree
}

private func makeBalancedFourWindowTree() -> BSPTree {
    let tree = BSPTree()
    let root = BSPNode()
    root.left = BSPNode()
    root.right = BSPNode()
    root.splitOverride = .horizontal
    root.left?.splitOverride = .vertical
    root.right?.splitOverride = .vertical
    root.left?.parent = root
    root.right?.parent = root
    root.left?.left = BSPNode(window: makeWindow(id: 1))
    root.left?.right = BSPNode(window: makeWindow(id: 2))
    root.right?.left = BSPNode(window: makeWindow(id: 3))
    root.right?.right = BSPNode(window: makeWindow(id: 4))
    root.left?.left?.parent = root.left
    root.left?.right?.parent = root.left
    root.right?.left?.parent = root.right
    root.right?.right?.parent = root.right
    tree.root = root
    return tree
}
