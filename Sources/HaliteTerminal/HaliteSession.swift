import AppKit
import Combine
import Foundation

/// 터미널 인스턴스 1개. PTY + 파서 + (장차) Grid + 렌더 상태를 묶음.
/// 호스트(cmux / halite.app)가 생성·소유하고 `HaliteTerminalView`에 주입.
public final class HaliteSession: ObservableObject {
    public private(set) var config: HaliteConfig

    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String? = nil
    @Published public private(set) var processExited: Bool = false
    public private(set) var exitCode: Int32? = nil

    /// VTParser가 발행하는 의미적 이벤트.
    public let outputEvents = PassthroughSubject<HaliteOutputEvent, Never>()

    // 호스트가 구독하는 콜백. weak 캡처 권장.
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?

    private let pty = PTYHost()
    private let parser = VTParser()

    public init(config: HaliteConfig) {
        self.config = config

        parser.delegate = self

        pty.onData = { [weak self] data in
            self?.handlePTYData(data)
        }
        pty.onExit = { [weak self] code in
            self?.handlePTYExit(code: code)
        }

        do {
            try pty.spawn(
                argv: config.argv,
                env: config.env,
                cwd: config.cwd,
                cols: 80,
                rows: 24
            )
        } catch {
            NSLog("halite: PTY spawn failed: \(error)")
        }
    }

    /// 키 이벤트 외의 추가 입력 (예: 호스트가 합성한 텍스트).
    public func write(_ bytes: Data) {
        pty.write(bytes)
    }

    public func resize(cols: Int, rows: Int) {
        pty.resize(cols: cols, rows: rows)
    }

    public func clearSelection() {
        // TODO(M8)
    }

    /// 폰트/색상/팔레트 변경 등 hot-reload 시 호출.
    public func updateConfig(_ config: HaliteConfig) {
        self.config = config
        // TODO: 렌더러/아틀라스/파서로 전파
    }

    public func terminate() {
        pty.terminate()
    }

    // MARK: - Internals

    private func handlePTYData(_ data: Data) {
        onOutput?(data)
        parser.feed(data)
    }

    private func handlePTYExit(code: Int32) {
        processExited = true
        exitCode = code
        onExit?(code)
    }

    /// 파서 이벤트를 outputEvents로 forward + 일부는 세션 상태 갱신
    /// (예: OSC 0/2 → title).
    fileprivate func dispatchTitleIfNeeded(_ oscParams: [String]) {
        guard oscParams.count >= 2 else { return }
        switch oscParams[0] {
        case "0", "2":
            let newTitle = oscParams[1]
            if newTitle != title {
                title = newTitle
                onTitleChanged?(newTitle)
            }
        default:
            break
        }
    }
}

extension HaliteSession: VTParserDelegate {
    public func vtParser(_ parser: VTParser, didEmitText text: String) {
        outputEvents.send(.text(text))
    }

    public func vtParser(_ parser: VTParser, didExecute byte: UInt8) {
        if byte == 0x07 { onBell?() }
        outputEvents.send(.execute(byte))
    }

    public func vtParser(
        _ parser: VTParser,
        didEmitCSI params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        outputEvents.send(.csi(
            params: params,
            intermediates: intermediates,
            finalByte: finalByte,
            privateMarker: privateMarker
        ))
    }

    public func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {
        dispatchTitleIfNeeded(params)
        outputEvents.send(.osc(params))
    }
}
