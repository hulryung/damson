import AppKit
import UserNotifications
import DamsonAgents
import DamsonTerminal

final class CommandNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = CommandNotificationPolicy.enabledKey
    private static let paneKey = "damson.paneID"
    var reveal: ((DamsonSession) -> Void)?
    var isFocused: ((DamsonSession) -> Bool)?
    private var observer: NSObjectProtocol?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        observer = NotificationCenter.default.addObserver(forName: DamsonSession.commandCompleted, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let session = note.object as? DamsonSession,
                  let result = note.userInfo?["completion"] as? CommandCompletion,
                  CommandNotificationPolicy.shouldNotify(
                      result, enabled: UserDefaults.standard.bool(forKey: Self.enabledKey),
                      threshold: CommandNotificationPolicy.threshold(),
                      appActive: NSApp.isActive, paneFocused: self.isFocused?(session) == true) else { return }
            let content = UNMutableNotificationContent()
            content.title = CommandNotificationPolicy.title(for: result)
            content.body = session.currentWorkingDirectory ?? session.currentDirectory ?? "Damson terminal"
            // Route the click by pane id, not a retained closure: the registry holds sessions
            // weakly, and restored panes keep their id across a keeper relaunch.
            content.userInfo = [Self.paneKey: PaneRegistry.shared.id(for: session).uuidString]
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            // The setting can also be turned on from Settings, which cannot prompt; asking here
            // is a no-op once the user has decided.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { UNUserNotificationCenter.current().add(request) }
            }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func toggle() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                UserDefaults.standard.set(granted, forKey: Self.enabledKey)
                if !granted {
                    let alert = NSAlert()
                    alert.messageText = "Notifications are disabled"
                    alert.informativeText = error?.localizedDescription ?? "Allow Damson notifications in System Settings → Notifications."
                    alert.runModal()
                }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let paneID = (response.notification.request.content.userInfo[Self.paneKey] as? String).flatMap(UUID.init)
        DispatchQueue.main.async { [weak self] in
            // A pane closed before the click: just bring the app forward.
            guard let paneID, let session = PaneRegistry.shared.session(for: paneID) else {
                NSApp.activate(ignoringOtherApps: true); return
            }
            self?.reveal?(session)
        }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
