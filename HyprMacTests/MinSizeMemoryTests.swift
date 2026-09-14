import Cocoa
import XCTest
@testable import HyprMac

// What MinSizeMemory is allowed to believe, and on what evidence. A seed
// is a hint; only a readback the app refused to shrink below is a
// constraint. Zero on an axis means "nothing has refused anything here".

final class MinSizeMemoryTests: XCTestCase {

    func testObservedEvidenceReplacesASeededHintInsteadOfMergingWithIt() {
        let window = makeWindow(id: 70)
        window.observedMinSize = CGSize(width: 520, height: 360)
        let memory = MinSizeMemory()
        memory.prime([window])

        memory.recordObserved(window, target: CGSize(width: 480, height: 700),
                              actual: CGSize(width: 1200, height: 700),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        // the seeded 360 was never refused by anything, so it does not get
        // to ride along as if it had been
        XCTAssertEqual(memory.minimumSize(for: window), CGSize(width: 1200, height: 0))
    }

    func testOneAxisEvidenceLeavesTheOtherAxisUnknown() {
        let window = makeWindow(id: 71)
        let memory = MinSizeMemory()

        memory.recordObserved(window, target: CGSize(width: 1100, height: 600),
                              actual: CGSize(width: 1100, height: 900),
                              widthConflict: false, heightConflict: true,
                              phase: .candidate)

        XCTAssertEqual(memory.minimumSize(for: window), CGSize(width: 0, height: 900))
    }

    func testSecondObservationRaisesOnlyTheAxisItRefused() {
        let window = makeWindow(id: 72)
        let memory = MinSizeMemory()
        memory.recordObserved(window, target: CGSize(width: 480, height: 700),
                              actual: CGSize(width: 1200, height: 700),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        memory.recordObserved(window, target: CGSize(width: 1100, height: 600),
                              actual: CGSize(width: 1100, height: 900),
                              widthConflict: false, heightConflict: true,
                              phase: .candidate)

        XCTAssertEqual(memory.minimumSize(for: window), CGSize(width: 1200, height: 900))
    }

    func testConstraintWiderThanMostOfTheScreenIsKept() {
        // 1700 is 88% of a 1920-wide screen. it still fits beside nothing,
        // but it fits above and below something, so capping it would throw
        // away a real constraint.
        let window = makeWindow(id: 73)
        let memory = MinSizeMemory()

        memory.recordObserved(window, target: CGSize(width: 940, height: 400),
                              actual: CGSize(width: 1700, height: 400),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        XCTAssertEqual(memory.minimumSize(for: window), CGSize(width: 1700, height: 0))
    }

    func testWholeSlotAcceptKeepsAFullSlotOnlyWindowsBound() {
        // a window that only ever fits the whole slot accepts the whole
        // slot. that is not evidence it can be smaller.
        let window = makeWindow(id: 74)
        let memory = MinSizeMemory()
        memory.recordObserved(window, target: CGSize(width: 940, height: 500),
                              actual: CGSize(width: 1700, height: 900),
                              widthConflict: true, heightConflict: true,
                              phase: .candidate)

        memory.lowerIfAccepted(window, actual: CGSize(width: 1700, height: 900))

        XCTAssertEqual(memory.minimumSize(for: window), CGSize(width: 1700, height: 900))
    }

    func testAcceptedSmallerSizeLowersOnlyTheAxisThatCameDown() {
        let window = makeWindow(id: 75)
        let memory = MinSizeMemory()
        memory.recordObserved(window, target: CGSize(width: 600, height: 500),
                              actual: CGSize(width: 1200, height: 900),
                              widthConflict: true, heightConflict: true,
                              phase: .candidate)

        memory.lowerIfAccepted(window, actual: CGSize(width: 800, height: 900))

        XCTAssertEqual(memory.minimumSize(for: window), CGSize(width: 800, height: 900))
    }

    func testSubPixelAcceptCannotRatchetTheFloorDown() {
        let window = makeWindow(id: 76)
        let memory = MinSizeMemory()
        memory.recordObserved(window, target: CGSize(width: 600, height: 500),
                              actual: CGSize(width: 1200, height: 900),
                              widthConflict: true, heightConflict: true,
                              phase: .candidate)

        memory.lowerIfAccepted(window, actual: CGSize(width: 1195, height: 900))

        XCTAssertEqual(memory.minimumSize(for: window), CGSize(width: 1200, height: 900))
    }

    func testSentinelEvidenceIsRefusedOutright() {
        let window = makeWindow(id: 77)
        let memory = MinSizeMemory()

        memory.recordObserved(window, target: CGSize(width: 600, height: 500),
                              actual: CGSize(width: 20000, height: 900),
                              widthConflict: true, heightConflict: true,
                              phase: .candidate)

        XCTAssertEqual(memory.minimumSize(for: window), .zero)
        XCTAssertNil(window.observedMinSize)
    }

    func testASeededHintIsRememberedAsAHint() {
        let window = makeWindow(id: 79)
        window.observedMinSize = CGSize(width: 520, height: 360)
        let memory = MinSizeMemory()

        memory.prime([window])

        XCTAssertEqual(memory.entry(for: 79),
                       MinSizeMemory.Entry(size: CGSize(width: 520, height: 360),
                                           provenance: .seeded))
        XCTAssertEqual(window.minSizeProvenance, .seeded)
    }

    func testRefusalEvidenceIsRememberedAsAConstraint() {
        let window = makeWindow(id: 80)
        window.observedMinSize = CGSize(width: 520, height: 360)
        let memory = MinSizeMemory()
        memory.prime([window])

        memory.recordObserved(window, target: CGSize(width: 480, height: 700),
                              actual: CGSize(width: 1200, height: 700),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        XCTAssertEqual(memory.entry(for: 80),
                       MinSizeMemory.Entry(size: CGSize(width: 1200, height: 0),
                                           provenance: .observed))
        XCTAssertEqual(window.minSizeProvenance, .observed)
    }

    func testPrimingDoesNotDowngradeAConstraintBackToAHint() {
        let window = makeWindow(id: 81)
        let memory = MinSizeMemory()
        memory.recordObserved(window, target: CGSize(width: 480, height: 700),
                              actual: CGSize(width: 1200, height: 700),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        memory.prime([window])

        XCTAssertEqual(memory.entry(for: 81)?.provenance, .observed)
    }

    func testLoweringKeepsTheProvenanceOfTheBoundItLowers() {
        let window = makeWindow(id: 82)
        window.observedMinSize = CGSize(width: 520, height: 360)
        let memory = MinSizeMemory()
        memory.prime([window])

        memory.lowerIfAccepted(window, actual: CGSize(width: 400, height: 340))

        // an accepted frame relaxes the guess, it does not turn it into a
        // constraint the app imposed
        XCTAssertEqual(memory.entry(for: 82),
                       MinSizeMemory.Entry(size: CGSize(width: 400, height: 340),
                                           provenance: .seeded))
    }

    func testLoweringAnUnknownWindowDoesNothing() {
        let window = makeWindow(id: 78)
        let memory = MinSizeMemory()

        memory.lowerIfAccepted(window, actual: CGSize(width: 400, height: 300))

        XCTAssertEqual(memory.minimumSize(for: window), .zero)
        XCTAssertNil(window.observedMinSize)
    }

    // MARK: - per-app hints

    private func outlookWindow(_ id: CGWindowID) -> HyprWindow {
        let window = makeWindow(id: id)
        window.bundleID = "com.microsoft.Outlook"
        return window
    }

    func testANewWindowOfTheSameAppStartsFromWhatItsSiblingRefused() {
        let memory = MinSizeMemory()
        let first = outlookWindow(90)
        memory.recordObserved(first, target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        let second = outlookWindow(91)
        memory.prime([second])

        XCTAssertEqual(memory.minimumSize(for: second), CGSize(width: 938, height: 0))
        XCTAssertEqual(memory.entry(for: 91)?.provenance, .appHint)
        XCTAssertEqual(second.minSizeProvenance, .appHint)
    }

    func testAnAppHintDoesNotReachAnotherApp() {
        let memory = MinSizeMemory()
        memory.recordObserved(outlookWindow(92), target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        let safari = makeWindow(id: 93)
        safari.bundleID = "com.apple.Safari"
        memory.prime([safari])

        XCTAssertNil(memory.entry(for: 93))
    }

    func testTheWindowsOwnEvidenceReplacesTheHintEvenWhenItIsLower() {
        let memory = MinSizeMemory()
        memory.recordObserved(outlookWindow(94), target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)
        let second = outlookWindow(95)
        memory.prime([second])

        memory.recordObserved(second, target: CGSize(width: 600, height: 841),
                              actual: CGSize(width: 700, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        XCTAssertEqual(memory.entry(for: 95),
                       MinSizeMemory.Entry(size: CGSize(width: 700, height: 0),
                                           provenance: .observed))
    }

    func testTheHintIsThePerAxisMaxOfWhatTheAppsWindowsRefused() {
        let memory = MinSizeMemory()
        memory.recordObserved(outlookWindow(96), target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)
        memory.recordObserved(outlookWindow(97), target: CGSize(width: 900, height: 400),
                              actual: CGSize(width: 900, height: 620),
                              widthConflict: false, heightConflict: true,
                              phase: .candidate)

        let third = outlookWindow(98)
        memory.prime([third])

        XCTAssertEqual(memory.minimumSize(for: third), CGSize(width: 938, height: 620))
    }

    func testAHintNeverOverwritesAWindowThatAlreadyHasAnEntry() {
        let memory = MinSizeMemory()
        let veteran = outlookWindow(99)
        memory.recordObserved(veteran, target: CGSize(width: 600, height: 841),
                              actual: CGSize(width: 700, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)
        memory.recordObserved(outlookWindow(100), target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        memory.prime([veteran])

        XCTAssertEqual(memory.entry(for: 99),
                       MinSizeMemory.Entry(size: CGSize(width: 700, height: 0),
                                           provenance: .observed))
    }

    func testAnAcceptedSizeBelowTheHintLowersItForTheNextWindow() {
        let memory = MinSizeMemory()
        memory.recordObserved(outlookWindow(103), target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)
        let second = outlookWindow(104)
        memory.prime([second])

        // this window took 744 without complaint, so 938 is one window's
        // floor and not the app's
        memory.lowerIfAccepted(second, actual: CGSize(width: 744, height: 841))

        let third = outlookWindow(105)
        memory.prime([third])
        XCTAssertEqual(memory.minimumSize(for: third), CGSize(width: 744, height: 0))
    }

    func testAWindowWithItsOwnEvidenceAlsoLowersTheAppsHint() {
        let memory = MinSizeMemory()
        let veteran = outlookWindow(106)
        memory.recordObserved(veteran, target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        memory.lowerIfAccepted(veteran, actual: CGSize(width: 700, height: 841))

        let next = outlookWindow(107)
        memory.prime([next])
        XCTAssertEqual(memory.minimumSize(for: next), CGSize(width: 700, height: 0))
    }

    func testWindowsWithNoBundleIDDoNotShareAHintBucket() {
        let memory = MinSizeMemory()
        let anonymous = makeWindow(id: 108)
        anonymous.bundleID = ""
        memory.recordObserved(anonymous, target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)

        let stranger = makeWindow(id: 109)
        stranger.bundleID = ""
        memory.prime([stranger])

        XCTAssertNil(memory.entry(for: 109), "an empty bundle id names no app")
    }

    func testTheWindowsOwnMeasurementReplacesAHintTheAttemptSetAside() {
        let memory = MinSizeMemory()
        memory.recordObserved(outlookWindow(112), target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)
        let second = outlookWindow(113)
        memory.prime([second])

        memory.adoptOwnEvidence(second, accepted: CGSize(width: 744, height: 841))

        XCTAssertEqual(memory.entry(for: 113),
                       MinSizeMemory.Entry(size: CGSize(width: 744, height: 0),
                                           provenance: .observed))
    }

    func testAHintDoesNotCountAsObservedEvidence() {
        let memory = MinSizeMemory()
        memory.recordObserved(outlookWindow(101), target: CGSize(width: 744, height: 841),
                              actual: CGSize(width: 938, height: 841),
                              widthConflict: true, heightConflict: false,
                              phase: .candidate)
        let second = outlookWindow(102)
        memory.prime([second])

        memory.lowerIfAccepted(second, actual: CGSize(width: 800, height: 0))

        // lowering relaxes the estimate; it does not promote a guess into a
        // bound the app imposed
        XCTAssertEqual(memory.entry(for: 102)?.provenance, .appHint)
    }
}
