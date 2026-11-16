import AppKit
import Quartz

/// Retains the preview datasource for the lifetime of the shared Quick Look panel.
final class FileContextActions: NSObject, QLPreviewPanelDataSource {
    static let shared = FileContextActions()
    private var previewURL: URL?

    func preview(_ url: URL) {
        guard let local = ContextMenuFile.localURL(url), let panel = QLPreviewPanel.shared() else { return }
        previewURL = local
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    /// Opens a text file in the file's default app when that is a known editor, else in the
    /// first installed known editor (see `EditorLauncher`), else TextEdit without a line.
    func edit(_ location: FileLocation) {
        guard let local = ContextMenuFile.localURL(location.url) else { NSSound.beep(); return }
        var target = location
        target.url = local
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: local).flatMap { Bundle(url: $0)?.bundleIdentifier }
        if let command = EditorLauncher.choose(defaultAppBundleID: defaultApp, location: target,
                                               appURL: { workspace.urlForApplication(withBundleIdentifier: $0) }) {
            let process = Process()
            process.executableURL = command.executable
            process.arguments = command.arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run(); return } catch { NSSound.beep(); return }
        }
        guard let editor = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSSound.beep(); return
        }
        workspace.open([local], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }
}

/// Menu-item payload: `representedObject` needs an object for a Swift struct to survive.
final class ContextFileLocation: NSObject {
    let location: FileLocation
    init(_ location: FileLocation) { self.location = location }
}
