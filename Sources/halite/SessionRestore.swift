import AppKit
import HaliteTerminal

/// 세션 상태 복원 — 종료 시 창/탭/pane 레이아웃 + 각 pane의 cwd를 직렬화하고,
/// 시작 시 그 구조로 복원한다. cwd는 proc_pidinfo로 OS에서 직접 조회(셸 설정 무관).
///
/// 스크롤백 텍스트는 저장하지 않음 (레이아웃 + cwd만 — 터미널 복원의 표준 범위).

// MARK: - 직렬화 모델

/// pane 트리 노드의 직렬화 형태.
indirect enum RestorablePane: Codable {
    case leaf(cwd: String?)
    case split(direction: String, ratio: Double, first: RestorablePane, second: RestorablePane)
}

/// 한 윈도우 = 탭 배열. 각 탭은 pane 트리의 root.
struct RestorableWindow: Codable {
    var tabs: [RestorablePane]
    var selectedTab: Int
    /// 탭별 사용자 지정 제목(더블클릭 rename). `tabs`와 같은 순서·길이. 옵셔널이라
    /// 이 필드가 없던 구버전 저장 데이터도 그대로 디코드된다(전부 자동 제목으로 복원).
    var tabTitles: [String?]?
}

/// 전체 복원 상태.
struct RestorableState: Codable {
    var windows: [RestorableWindow]
}

// MARK: - 저장/로드

enum SessionRestore {
    private static let key = "halite.restorableState"

    static func save(_ state: RestorableState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> RestorableState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(RestorableState.self, from: data)
        else { return nil }
        return state
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - PaneNode ↔ RestorablePane 변환

extension PaneNode {
    /// 현재 트리를 직렬화 형태로. 각 leaf의 cwd는 proc_pidinfo로 조회.
    func toRestorable() -> RestorablePane {
        switch kind {
        case .leaf(let session, _):
            return .leaf(cwd: session.currentWorkingDirectory)
        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir == .horizontal ? "horizontal" : "vertical",
                ratio: Double(ratio),
                first: first.toRestorable(),
                second: second.toRestorable()
            )
        }
    }

    /// 직렬화 형태로부터 트리 재구성. 각 leaf는 cwd에서 새 세션 spawn.
    /// parent 링크도 연결.
    static func from(restorable: RestorablePane) -> PaneNode {
        switch restorable {
        case .leaf(let cwd):
            var config = HaliteConfig.fromUserDefaults()
            // 저장된 cwd가 아직 존재하면 거기서, 아니면 fromUserDefaults의 기본(홈).
            if let cwd = cwd, FileManager.default.fileExists(atPath: cwd) {
                config.cwd = cwd
            }
            let session = HaliteSession(config: config)
            return PaneNode.leaf(session)
        case .split(let dirStr, let ratio, let first, let second):
            let dir: SplitDirection = (dirStr == "vertical") ? .vertical : .horizontal
            let a = from(restorable: first)
            let b = from(restorable: second)
            let node = PaneNode(kind: .split(
                direction: dir, first: a, second: b, ratio: CGFloat(ratio)
            ))
            a.parent = node
            b.parent = node
            return node
        }
    }
}
