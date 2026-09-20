import XCTest
@testable import HyprMac

// CommandRunnerTests pin the `runCommand` execution boundary: how a
// command line is split, how a program token is resolved, and — the
// part that matters most — that nothing is ever handed to a shell.

final class CommandRunnerTests: XCTestCase {

    // MARK: - tokenizer

    private let home = "/Users/tester"

    func testPlainSplit() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("/usr/bin/true a b", home: home),
                       ["/usr/bin/true", "a", "b"])
    }

    func testCollapsesRunsOfWhitespace() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("  /bin/ls   -l\t-a  ", home: home),
                       ["/bin/ls", "-l", "-a"])
    }

    func testDoubleQuotesGroupSpaces() throws {
        XCTAssertEqual(try CommandLineParser.tokenize(#"/bin/echo "two words" tail"#, home: home),
                       ["/bin/echo", "two words", "tail"])
    }

    func testSingleQuotesGroupSpaces() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("/bin/echo 'two words'", home: home),
                       ["/bin/echo", "two words"])
    }

    func testBackslashEscapesSpace() throws {
        XCTAssertEqual(try CommandLineParser.tokenize(#"/bin/echo two\ words"#, home: home),
                       ["/bin/echo", "two words"])
    }

    func testBackslashEscapesQuote() throws {
        XCTAssertEqual(try CommandLineParser.tokenize(#"/bin/echo \"quoted\""#, home: home),
                       ["/bin/echo", "\"quoted\""])
    }

    func testEmptyLineThrowsEmpty() {
        XCTAssertThrowsError(try CommandLineParser.tokenize("   ", home: home)) { error in
            XCTAssertEqual(error as? CommandLineParser.ParseError, .empty)
        }
    }

    func testUnterminatedDoubleQuoteThrows() {
        XCTAssertThrowsError(try CommandLineParser.tokenize(#"/bin/echo "abc"#, home: home)) { error in
            XCTAssertEqual(error as? CommandLineParser.ParseError, .unterminatedQuote)
        }
    }

    func testUnterminatedSingleQuoteThrows() {
        XCTAssertThrowsError(try CommandLineParser.tokenize("/bin/echo 'abc", home: home)) { error in
            XCTAssertEqual(error as? CommandLineParser.ParseError, .unterminatedQuote)
        }
    }

    func testTrailingBackslashThrowsItsOwnError() {
        XCTAssertThrowsError(try CommandLineParser.tokenize(#"foo bar\"#)) { error in
            XCTAssertEqual(error as? CommandLineParser.ParseError, .trailingBackslash)
        }
    }

    func testNonBreakingSpaceSeparatesTokens() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("a\u{00A0}b"), ["a", "b"])
    }

    func testLeadingTildeExpands() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("/bin/ls ~/x", home: home),
                       ["/bin/ls", "/Users/tester/x"])
    }

    func testBareTildeExpands() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("/bin/ls ~", home: home),
                       ["/bin/ls", "/Users/tester"])
    }

    func testQuotedTildeDoesNotExpand() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("/bin/ls '~/x'", home: home),
                       ["/bin/ls", "~/x"])
    }

    func testTildeInsideATokenDoesNotExpand() throws {
        XCTAssertEqual(try CommandLineParser.tokenize("/bin/ls a~b", home: home),
                       ["/bin/ls", "a~b"])
    }

    func testEmptyQuotedTokenSurvives() throws {
        XCTAssertEqual(try CommandLineParser.tokenize(#"/bin/echo "" tail"#, home: home),
                       ["/bin/echo", "", "tail"])
    }

    // MARK: - resolver

    func testAbsolutePathResolves() throws {
        XCTAssertEqual(try ProgramResolver.resolve("/usr/bin/true").path, "/usr/bin/true")
    }

    func testBareNameResolvesThroughSearchPaths() throws {
        let url = try ProgramResolver.resolve("true", searchPaths: ["/nonexistent", "/usr/bin"])
        XCTAssertEqual(url.path, "/usr/bin/true")
    }

    func testRelativePathResolvesAgainstHome() throws {
        let url = try ProgramResolver.resolve("bin/true", home: "/usr")
        XCTAssertEqual(url.path, "/usr/bin/true")
    }

    func testEmptyProgramIsNotFoundWithAPlainMessage() {
        XCTAssertThrowsError(try ProgramResolver.resolve("")) { error in
            XCTAssertEqual(error as? ProgramResolver.ResolveError, .notFound)
        }
        XCTAssertEqual(CommandRunner.validate(#""""#), .programNotFound(""))
        XCTAssertEqual(CommandRunner.ValidationError.programNotFound("").message, "Enter a program to run.")
    }

    func testMissingProgramIsNotFound() {
        XCTAssertThrowsError(
            try ProgramResolver.resolve("definitely-not-a-program-xyz",
                                        searchPaths: ["/usr/bin", "/bin"])
        ) { error in
            XCTAssertEqual(error as? ProgramResolver.ResolveError, .notFound)
        }
    }

    func testDirectoryPathIsNotExecutable() {
        XCTAssertThrowsError(try ProgramResolver.resolve("/usr/bin")) { error in
            XCTAssertEqual(error as? ProgramResolver.ResolveError, .notExecutable)
        }
    }

    func testNonExecutableFileIsNotExecutable() throws {
        let path = try makeTempFile(named: "plain.txt", executable: false)
        XCTAssertThrowsError(try ProgramResolver.resolve(path)) { error in
            XCTAssertEqual(error as? ProgramResolver.ResolveError, .notExecutable)
        }
    }

    func testFallbackSearchPathsCoverTheUsualBinDirs() {
        XCTAssertEqual(ProgramResolver.fallbackSearchPaths.first, "/opt/homebrew/bin")
        XCTAssertTrue(ProgramResolver.fallbackSearchPaths.contains("/usr/bin"))
        XCTAssertTrue(ProgramResolver.defaultSearchPaths().contains("/usr/bin"))
    }

    // MARK: - validate

    func testValidateEmpty() {
        XCTAssertEqual(CommandRunner.validate(""), .empty)
    }

    func testValidateUnterminatedQuote() {
        XCTAssertEqual(CommandRunner.validate(#"/bin/echo "abc"#), .unterminatedQuote)
    }

    func testValidateTrailingBackslash() {
        XCTAssertEqual(CommandRunner.validate(#"/bin/echo abc\"#), .trailingBackslash)
        XCTAssertEqual(CommandRunner.ValidationError.trailingBackslash.message,
                       "Command ends with a backslash.")
    }

    func testValidateUnknownProgram() {
        XCTAssertEqual(CommandRunner.validate("definitely-not-a-program-xyz"),
                       .programNotFound("definitely-not-a-program-xyz"))
    }

    func testValidateAcceptsAnAbsoluteProgramWithArguments() {
        XCTAssertNil(CommandRunner.validate("/usr/bin/true --x"))
    }

    func testValidationMessagesAreUserFacing() {
        XCTAssertEqual(CommandRunner.ValidationError.empty.message, "Enter a command.")
        XCTAssertEqual(CommandRunner.ValidationError.unterminatedQuote.message,
                       "Unbalanced quote in command.")
        XCTAssertEqual(CommandRunner.ValidationError.programNotFound("foo").message,
                       "Program not found: foo")
        XCTAssertEqual(CommandRunner.ValidationError.programNotExecutable("/path").message,
                       "Program is not executable: /path")
    }

    // MARK: - run

    func testRunSucceeds() {
        XCTAssertNil(CommandRunner().run(command: "/usr/bin/true"))
    }

    func testRunReportsAMissingProgram() {
        XCTAssertEqual(CommandRunner().run(command: "/nonexistent/prog"),
                       .programNotFound("/nonexistent/prog"))
    }

    func testRunActuallyLaunchesTheProgram() throws {
        let dir = try makeTempDir()
        let target = dir + "/created"
        XCTAssertNil(CommandRunner().run(command: "/usr/bin/touch \(target)"))
        XCTAssertTrue(waitForFile(target), "expected the child process to create its file")
    }

    func testSemicolonIsAnArgumentNotACommandSeparator() throws {
        let dir = try makeTempDir()
        let second = dir + "/second"
        // /usr/bin/true ignores its arguments, so under a shell the ";" would
        // start a second command and create the file — directly, it cannot.
        XCTAssertNil(CommandRunner().run(command: "/usr/bin/true ; /usr/bin/touch \(second)"))
        XCTAssertFalse(waitForFile(second, timeout: 1),
                       "a shell ran the command line — the ';' must stay an argument")
    }

    func testRedirectionIsAnArgumentNotARedirect() throws {
        let dir = try makeTempDir()
        let target = dir + "/redirected"
        XCTAssertNil(CommandRunner().run(command: "/usr/bin/true > \(target)"))
        XCTAssertFalse(waitForFile(target, timeout: 1),
                       "a shell ran the command line — the '>' must stay an argument")
    }

    func testGlobsAreNotExpanded() throws {
        let dir = try makeTempDir()
        XCTAssertNil(CommandRunner().run(command: "/usr/bin/touch \(dir)/*"))
        // a literal "*" file proves nothing expanded the pattern
        XCTAssertTrue(waitForFile(dir + "/*"))
    }

    // MARK: - helpers

    private func makeTempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("hyprmac-cmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    private func makeTempFile(named name: String, executable: Bool) throws -> String {
        let path = (try makeTempDir() as NSString).appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: path, contents: Data("x".utf8),
            attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        return path
    }

    /// poll instead of sleeping — the child is launched asynchronously
    private func waitForFile(_ path: String, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return FileManager.default.fileExists(atPath: path)
    }
}
