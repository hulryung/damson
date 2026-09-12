// Isolated WebKit scroll target. JavaScript observes actual browser scrolling;
// all input must come through the permitted Damson Computer helper.
import AppKit
import WebKit

final class ScrollFixture: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--occluder") {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Damson Scroll Occlusion Fixture"
            window.level = .floating
            window.center()
            window.orderFrontRegardless()
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "acceptance")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Damson Computer Scroll Acceptance"
        window.contentView = web
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.loadHTMLString("""
        <!doctype html><meta charset="utf-8"><title>Scroll acceptance</title>
        <style>body { margin:0; width:2200px; height:3000px; font:24px system-ui;
        background:repeating-linear-gradient(0deg,#dbeafe 0 100px,#fff 100px 200px) }
        h1 {padding:30px} p {margin:100px 30px}</style>
        <h1>Damson scroll acceptance</h1><p>Observe real horizontal and vertical movement.</p>
        <script>
        const wheelEvents=[];
        addEventListener('wheel', e=>{
          wheelEvents.push({dx:e.deltaX,dy:e.deltaY,trusted:e.isTrusted});
          if(wheelEvents.length>100) wheelEvents.shift();
        }, {passive:true});
        setInterval(()=>webkit.messageHandlers.acceptance.postMessage({
          x:scrollX,y:scrollY,wheelEvents
        }),50);
        </script>
        """, baseURL: nil)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard var state = message.body as? [String: Any] else { return }
        state["pid"] = getpid()
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/damson-computer-scroll-state.json"), options: .atomic)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let fixture = ScrollFixture()
application.delegate = fixture
application.run()
