import Foundation

/// Semantic output events that `DamsonSession` emits via the parser.
/// The host (view/renderer) branches on each case.
public enum DamsonOutputEvent {
    case text(String)
    case execute(UInt8)
    case csi(params: [Int], intermediates: [UInt8], finalByte: UInt8, privateMarker: UInt8?)
    case osc([String])
}
