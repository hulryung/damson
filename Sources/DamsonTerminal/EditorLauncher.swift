import Foundation

/// A file and the position to open it at. `line`/`column` are 1-based; nil means unknown.
struct FileLocation: Equatable {
    var url: URL
    var line: Int?
    var column: Int?
}

/// Known editors and how each one's command line takes a line/column.
///
/// Pure data + argument building so it can be tested without launching anything; the view
/// resolves bundle IDs through `NSWorkspace` and runs the command.
enum EditorLauncher {
    enum Style: Equatable {
        /// `code --goto path:line:col` (VS Code and its forks).
        case gotoFlag
        /// `subl path:line:col`, `zed path:line:col`.
        case colonSuffix
        /// `open -na App.app --args --line N --column C path` (JetBrains).
        case jetBrains
        /// `xed --line N path` (Xcode; no column).
        case xed
    }

    struct Editor: Equatable {
        let name: String
        let bundleIDs: [String]
        /// Command-line entry points inside the bundle, first executable wins.
        /// Empty for JetBrains, which is launched through `open`.
        let cliPaths: [String]
        let style: Style
        /// Considered when the file's default app is not a known editor. Xcode is excluded:
        /// many people have it installed only for its toolchain.
        let fallback: Bool
    }

    static let editors: [Editor] = [
        Editor(name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode"],
               cliPaths: ["Contents/Resources/app/bin/code"], style: .gotoFlag, fallback: true),
        Editor(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"],
               cliPaths: ["Contents/Resources/app/bin/cursor", "Contents/Resources/app/bin/code"],
               style: .gotoFlag, fallback: true),
        Editor(name: "Zed", bundleIDs: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
               cliPaths: ["Contents/MacOS/cli"], style: .colonSuffix, fallback: true),
        Editor(name: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"],
               cliPaths: ["Contents/SharedSupport/bin/subl"], style: .colonSuffix, fallback: true),
        Editor(name: "Windsurf", bundleIDs: ["com.exafunction.windsurf"],
               cliPaths: ["Contents/Resources/app/bin/windsurf"], style: .gotoFlag, fallback: true),
        Editor(name: "VSCodium", bundleIDs: ["com.vscodium"],
               cliPaths: ["Contents/Resources/app/bin/codium"], style: .gotoFlag, fallback: true),
        Editor(name: "Visual Studio Code - Insiders", bundleIDs: ["com.microsoft.VSCodeInsiders"],
               cliPaths: ["Contents/Resources/app/bin/code-insiders", "Contents/Resources/app/bin/code"],
               style: .gotoFlag, fallback: true),
        Editor(name: "JetBrains IDE", bundleIDs: [
            "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm",
            "com.jetbrains.pycharm.ce", "com.jetbrains.WebStorm", "com.jetbrains.goland",
            "com.jetbrains.CLion", "com.jetbrains.rider", "com.jetbrains.PhpStorm",
            "com.jetbrains.rubymine", "com.jetbrains.rustrover",
            "com.google.android.studio",
        ], cliPaths: [], style: .jetBrains, fallback: true),
        Editor(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"],
               cliPaths: ["Contents/Developer/usr/bin/xed"], style: .xed, fallback: false),
    ]

    struct Command: Equatable {
        let executable: URL
        let arguments: [String]
    }

    /// The command that opens `location` in `editor` installed at `app`, or nil when the
    /// bundle has no usable entry point. `isExecutable` is injectable for tests.
    static func command(for editor: Editor, app: URL, location: FileLocation,
                        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Command? {
        let path = location.url.path
        let line = location.line.flatMap { $0 > 0 ? $0 : nil }
        let column = line == nil ? nil : location.column.flatMap { $0 > 0 ? $0 : nil }
        var position = path
        if let line { position += ":\(line)" + (column.map { ":\($0)" } ?? "") }
        if editor.style == .jetBrains {
            var args = ["-na", app.path, "--args"]
            if let line { args += ["--line", "\(line)"] }
            if let column { args += ["--column", "\(column)"] }
            return Command(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: args + [path])
        }
        guard let cli = editor.cliPaths.map({ app.appendingPathComponent($0) })
            .first(where: { isExecutable($0.path) }) else { return nil }
        switch editor.style {
        case .gotoFlag: return Command(executable: cli, arguments: ["--goto", position])
        case .colonSuffix: return Command(executable: cli, arguments: [position])
        case .xed: return Command(executable: cli, arguments: (line.map { ["--line", "\($0)"] } ?? []) + [path])
        case .jetBrains: return nil
        }
    }

    /// The editor to use: the file's default app when it is a known editor, otherwise the
    /// first installed fallback editor. `appURL` maps a bundle ID to an installed app.
    static func choose(defaultAppBundleID: String?, location: FileLocation,
                       appURL: (String) -> URL?,
                       isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Command? {
        func launch(_ editor: Editor, _ id: String) -> Command? {
            appURL(id).flatMap { command(for: editor, app: $0, location: location, isExecutable: isExecutable) }
        }
        if let id = defaultAppBundleID, let editor = editors.first(where: { $0.bundleIDs.contains(id) }),
           let command = launch(editor, id) {
            return command
        }
        for editor in editors where editor.fallback {
            for id in editor.bundleIDs {
                if let command = launch(editor, id) { return command }
            }
        }
        return nil
    }
}
