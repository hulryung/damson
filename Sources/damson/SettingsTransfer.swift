import AppKit
import DamsonSettings
import UniformTypeIdentifiers

/// Export / import of the whole settings set (Advanced › Settings File). The file format
/// and what goes in it are `SettingsCatalog`'s; this is only the panels and the alerts.
enum SettingsTransfer {
    static func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Damson Settings"
        panel.nameFieldStringValue = "Damson Settings.plist"
        panel.allowedContentTypes = [.propertyList]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsCatalog.exportData(from: .standard).write(to: url, options: .atomic)
        } catch {
            alert("Couldn't export settings", error.localizedDescription, style: .warning)
        }
    }

    static func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Damson Settings"
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try SettingsCatalog.importData(Data(contentsOf: url), into: .standard)
            KeyBindingStore.shared.reloadFromDefaults()
            SettingsModel.applySideEffects()
            var detail = "\(result.applied.count) settings imported."
            if !result.skipped.isEmpty {
                detail += " \(result.skipped.count) skipped because this version of Damson doesn't know them: "
                    + result.skipped.joined(separator: ", ")
            }
            alert("Settings imported", detail, style: .informational)
        } catch {
            alert("Couldn't import settings", error.localizedDescription, style: .warning)
        }
    }

    private static func alert(_ title: String, _ text: String, style: NSAlert.Style) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = style
        a.runModal()
    }
}
