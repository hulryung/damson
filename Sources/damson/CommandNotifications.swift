import AppKit
import UserNotifications
import DamsonTerminal

final class CommandNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "damson.commandNotifications"
    var reveal: ((DamsonSession) -> Void)?
    var isFocused: ((DamsonSession) -> Bool)?
    private var pending: [String: () -> Void] = [:]
    private var observer: NSObjectProtocol?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        observer = NotificationCenter.default.addObserver(forName: DamsonSession.commandCompleted, object: nil, queue: .main) { [weak self] note in
            guard let self, UserDefaults.standard.bool(forKey: Self.enabledKey),
                  let session = note.object as? DamsonSession,
                  let result = note.userInfo?["completion"] as? CommandCompletion,
                  result.duration >= 10, !(NSApp.isActive && self.isFocused?(session) == true) else { return }
            let id = UUID().uuidString
            // Bound retention; closures hold sessions weakly, never prolong a shell's life.
            if self.pending.count >= 100 { self.pending.removeAll() }
            self.pending[id] = { [weak self, weak session] in
                guard let session else { return }
                self?.reveal?(session)
            }
            let content = UNMutableNotificationContent()
            let status = result.exitCode.map { $0 == 0 ? "Succeeded" : "Failed (exit \($0))" } ?? "Finished (status unknown)"
            content.title = "\(status) · \(Int(result.duration))s"
            content.body = session.currentDirectory ?? "Damson terminal"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
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
        DispatchQueue.main.async { [weak self] in self?.pending.removeValue(forKey: response.notification.request.identifier)?() }
        completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
