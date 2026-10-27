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

    func edit(_ url: URL, line: Int) {
        guard let local = ContextMenuFile.localURL(url) else { NSSound.beep(); return }
        // VS Code's documented command-line entry point preserves :line navigation.
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            let cli = app.appendingPathComponent("Contents/Resources/app/bin/code")
            if FileManager.default.isExecutableFile(atPath: cli.path) {
                let process = Process()
                process.executableURL = cli
                process.arguments = ["--goto", local.path + (line > 0 ? ":\(line)" : "")]
                do { try process.run(); return } catch { NSSound.beep(); return }
            }
        }
        guard let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            NSSound.beep(); return
        }
        NSWorkspace.shared.open([local], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if error != nil { DispatchQueue.main.async { NSSound.beep() } }
        }
    }
}
