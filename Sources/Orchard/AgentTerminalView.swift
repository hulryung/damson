import SwiftUI
import AppKit
import DamsonTerminal

/// Holds a weak reference to a tile's live terminal surface so the tile's +/- buttons can
/// drive per-terminal zoom (`zoomIn`/`zoomOut`/`resetZoom` are responder actions on the view).
final class SurfaceRef: ObservableObject {
    weak var view: DamsonSurfaceView?
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func resetZoom() { view?.resetZoom(nil) }
}

/// Like `DamsonTerminalView`, but captures the created `DamsonSurfaceView` into a `SurfaceRef`
/// so the tile can zoom this specific terminal with mouse buttons.
struct AgentTerminalView: NSViewRepresentable {
    let session: DamsonSession
    let ref: SurfaceRef
    var isActive: Bool = true

    func makeNSView(context: Context) -> DamsonSurfaceView {
        let view = DamsonSurfaceView(session: session)
        ref.view = view
        return view
    }

    func updateNSView(_ nsView: DamsonSurfaceView, context: Context) {
        nsView.isActive = isActive
        ref.view = nsView
    }
}
