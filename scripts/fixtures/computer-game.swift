// Loads a locally served game in an isolated WKWebView. Observes state only;
// all clicks and keys in acceptance must come through damson-computer.
import AppKit
import WebKit

final class GameFixture: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    let statePath = "/tmp/damson-computer-game-state.json"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let address = CommandLine.arguments.dropFirst().first ?? "http://127.0.0.1:8765/"
        guard let url = URL(string: address), ["127.0.0.1", "localhost"].contains(url.host ?? "") else { exit(2) }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "acceptance")
        let script = """
        (() => {
          const keys = [];
          document.addEventListener('keydown', event => {
            keys.push({key: event.key, trusted: event.isTrusted});
            if (keys.length > 30) keys.shift();
          }, true);
          setInterval(() => {
            const canvas = document.querySelector('canvas');
            let hash = 0;
            if (canvas) {
              const pixels = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
              for (let i = 0; i < pixels.length; i += 4) hash = ((hash << 5) - hash + pixels[i]) | 0;
            }
            window.webkit.messageHandlers.acceptance.postMessage({
              state: document.body?.dataset.state || '',
              status: document.querySelector('#status')?.textContent || '',
              canvasHash: hash, keys
            });
          }, 100);
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 780), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Damson Computer Game Acceptance"
        window.contentView = web
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: url))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard var state = message.body as? [String: Any] else { return }
        state["pid"] = getpid()
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let fixture = GameFixture()
application.delegate = fixture
application.run()
