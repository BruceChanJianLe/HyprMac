import XCTest
@testable import HyprMac

// RunCommandKeybindTests cover the settings side of the `runCommand`
// action: where it files in the keybind list, what the row says, and
// the editor's load / validate / build cycle.

final class RunCommandKeybindTests: XCTestCase {

    func testRunCommandFilesUnderApps() {
        XCTAssertEqual(
            KeybindCategory.from(.runCommand(label: "x", command: "/usr/bin/true")), .apps)
    }

    func testRowUsesTheLabelWhenThereIsOne() {
        let bind = Keybind(keyCode: 1, modifiers: .hypr,
                           action: .runCommand(label: "  Screenshot  ",
                                               command: "/usr/sbin/screencapture -i"))
        XCTAssertEqual(bind.actionDescription, "Screenshot")
        XCTAssertEqual(bind.actionIcon, "terminal")
    }

    func testRowFallsBackToTheProgramBasename() {
        let bind = Keybind(keyCode: 1, modifiers: .hypr,
                           action: .runCommand(label: "", command: "/usr/sbin/screencapture -i"))
        XCTAssertEqual(bind.actionDescription, "Run screencapture")
    }

    func testRowFallsBackAgainWhenTheCommandCannotBeParsed() {
        let bind = Keybind(keyCode: 1, modifiers: .hypr,
                           action: .runCommand(label: "", command: #"   "unbalanced"#))
        XCTAssertEqual(bind.actionDescription, "Run command")
    }

    @MainActor
    func testEditorLoadsAndRebuildsARunCommandBind() {
        let bind = Keybind(keyCode: 1, modifiers: [.hypr, .shift],
                           action: .runCommand(label: "Screenshot",
                                               command: "/usr/bin/true -i"))
        let vm = KeybindEditorViewModel()
        vm.load(bind)
        XCTAssertEqual(vm.selectedAction, .runCommand)
        XCTAssertEqual(vm.commandLabelParam, "Screenshot")
        XCTAssertEqual(vm.commandParam, "/usr/bin/true -i")
        XCTAssertEqual(vm.buildKeybind().action, bind.action)
        XCTAssertEqual(vm.buildKeybind().modifiers, bind.modifiers)
    }

    @MainActor
    func testEditorTrimsLabelAndCommandOnSave() {
        let vm = KeybindEditorViewModel()
        vm.recordedKeyCode = 1
        vm.selectedAction = .runCommand
        vm.commandLabelParam = "  Shot  "
        vm.commandParam = "  /usr/bin/true  "
        XCTAssertEqual(vm.buildKeybind().action,
                       .runCommand(label: "Shot", command: "/usr/bin/true"))
    }

    @MainActor
    func testEditorBlocksSaveUntilTheCommandResolves() {
        let vm = KeybindEditorViewModel()
        vm.recordedKeyCode = 1
        vm.selectedAction = .runCommand
        XCTAssertFalse(vm.canSave)
        XCTAssertEqual(vm.commandValidationMessage, "Enter a command.")

        vm.commandParam = "definitely-not-a-program-xyz"
        XCTAssertFalse(vm.canSave)
        XCTAssertEqual(vm.commandValidationMessage,
                       "Program not found: definitely-not-a-program-xyz")

        vm.commandParam = "/usr/bin/true"
        XCTAssertTrue(vm.canSave)
        XCTAssertNil(vm.commandValidationMessage)
    }

    @MainActor
    func testCommandValidationDoesNotBlockOtherActions() {
        let vm = KeybindEditorViewModel()
        vm.recordedKeyCode = 1
        vm.selectedAction = .closeWindow
        vm.commandParam = "definitely-not-a-program-xyz"
        XCTAssertNil(vm.commandValidationError)
        XCTAssertTrue(vm.canSave)
    }

    @MainActor
    func testEditorStillRequiresAChord() {
        let vm = KeybindEditorViewModel()
        vm.selectedAction = .runCommand
        vm.commandParam = "/usr/bin/true"
        XCTAssertFalse(vm.canSave)
    }
}
