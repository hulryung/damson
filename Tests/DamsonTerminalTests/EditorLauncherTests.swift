import XCTest
@testable import DamsonTerminal

final class EditorLauncherTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/한글 dir/main.swift")
    private func editor(_ name: String) -> EditorLauncher.Editor {
        EditorLauncher.editors.first { $0.name == name }!
    }
    private func run(_ name: String, line: Int?, column: Int?) -> EditorLauncher.Command? {
        EditorLauncher.command(for: editor(name), app: URL(fileURLWithPath: "/Applications/X.app"),
                               location: FileLocation(url: file, line: line, column: column),
                               isExecutable: { _ in true })
    }

    func testEachStylePassesLineAndColumn() {
        XCTAssertEqual(run("Visual Studio Code", line: 12, column: 5)?.arguments, ["--goto", file.path + ":12:5"])
        XCTAssertEqual(run("Visual Studio Code", line: 12, column: 5)?.executable.path,
                       "/Applications/X.app/Contents/Resources/app/bin/code")
        XCTAssertEqual(run("Zed", line: 12, column: nil)?.arguments, [file.path + ":12"])
        XCTAssertEqual(run("Sublime Text", line: 3, column: 9)?.executable.lastPathComponent, "subl")
        XCTAssertEqual(run("Xcode", line: 7, column: 2)?.arguments, ["--line", "7", file.path])
        let jb = run("JetBrains IDE", line: 4, column: 2)
        XCTAssertEqual(jb?.executable.path, "/usr/bin/open")
        XCTAssertEqual(jb?.arguments, ["-na", "/Applications/X.app", "--args", "--line", "4", "--column", "2", file.path])
    }

    func testMissingOrInvalidLineOpensPlainPath() {
        XCTAssertEqual(run("Visual Studio Code", line: nil, column: 4)?.arguments, ["--goto", file.path])
        XCTAssertEqual(run("Zed", line: 0, column: nil)?.arguments, [file.path])
        XCTAssertEqual(run("Xcode", line: nil, column: nil)?.arguments, [file.path])
    }

    func testBundleWithoutCLIIsSkipped() {
        let command = EditorLauncher.command(for: editor("Cursor"), app: URL(fileURLWithPath: "/A.app"),
                                             location: FileLocation(url: file), isExecutable: { $0.hasSuffix("/code") })
        XCTAssertEqual(command?.executable.lastPathComponent, "code")
        XCTAssertNil(EditorLauncher.command(for: editor("Zed"), app: URL(fileURLWithPath: "/A.app"),
                                            location: FileLocation(url: file), isExecutable: { _ in false }))
    }

    func testDefaultAppWinsThenFallbackOrder() {
        let installed = ["com.microsoft.VSCode": "/VS.app", "dev.zed.Zed": "/Zed.app", "com.apple.dt.Xcode": "/Xcode.app"]
        func choose(_ defaultApp: String?, _ apps: [String: String]) -> String? {
            EditorLauncher.choose(defaultAppBundleID: defaultApp, location: FileLocation(url: file, line: 1),
                                  appURL: { apps[$0].map { URL(fileURLWithPath: $0) } },
                                  isExecutable: { _ in true })?.executable.path
        }
        XCTAssertEqual(choose("dev.zed.Zed", installed), "/Zed.app/Contents/MacOS/cli")
        XCTAssertEqual(choose("com.apple.dt.Xcode", installed), "/Xcode.app/Contents/Developer/usr/bin/xed")
        // Not a known editor (TextEdit) → first installed fallback, never Xcode.
        XCTAssertEqual(choose("com.apple.TextEdit", installed), "/VS.app/Contents/Resources/app/bin/code")
        XCTAssertEqual(choose(nil, ["dev.zed.Zed": "/Zed.app"]), "/Zed.app/Contents/MacOS/cli")
        XCTAssertNil(choose(nil, ["com.apple.dt.Xcode": "/Xcode.app"]))
        XCTAssertNil(choose(nil, [:]))
    }
}
