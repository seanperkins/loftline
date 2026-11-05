import SwiftUI
import LoftLineKit

/// The error line of a sheet, above its buttons: nothing when `message` is nil. A sheet shows its own
/// failures (a file that cannot be written or read) because an alert set on the document sits under
/// the sheet, where SwiftUI drops it. A long message (a list of files) scrolls in a box of at most
/// 110 pt, so it cannot push the buttons out of a fixed-size sheet.
struct SheetErrorRow: View {
    var message: String?
    @State private var textHeight: CGFloat = 0

    private struct HeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        if let message {
            ScrollView {
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Color.errorText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            }
            .scrollIndicators(.visible)
            .onPreferenceChange(HeightKey.self) { textHeight = $0 }
            .frame(height: min(max(textHeight, 20), 110))
        }
    }
}
