import Foundation

/// 분할된 pane에서 "마우스 따라 포커스" — 클릭 없이 커서가 올라간 pane이 활성화된다.
/// UserDefaults("damson.focusFollowsMouse")에 Bool로 저장. **디폴트 켜짐.**
/// PaneLeafWrapper의 mouseEntered가 hover 시점마다 직접 읽는다(핫리로드 불필요).
enum FocusFollowsMouse {
    static var enabled: Bool {
        // bool(forKey:)는 미설정 시 false라 디폴트-켜짐을 못 준다 → object로 존재 확인.
        (UserDefaults.standard.object(forKey: "damson.focusFollowsMouse") as? Bool) ?? true
    }
}
