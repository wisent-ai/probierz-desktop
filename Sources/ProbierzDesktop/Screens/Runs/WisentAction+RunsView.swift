import SwiftUI
import WisentDesignSystem

@MainActor
extension WisentAction {
    /// A single action rendered inline inside an inspector column.
    func asButton() -> some View {
        WisentActionButton(action: self)
    }
}
