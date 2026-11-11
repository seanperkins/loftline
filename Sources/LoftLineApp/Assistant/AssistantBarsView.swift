import SwiftUI

/// The live link's bars above a window's canvas (spec 2, "What the user sees"): the Allow question, the assistant at work with
/// Disconnect, a standing Allow with Revoke, and the review marker with Dismiss.
struct AssistantBarsView: View {
    @ObservedObject var document: LoftLineDocument

    var body: some View {
        let bars = document.assistantBars
        let name = MacLinkHost.shared.name(of: document)
        VStack(spacing: 0) {
            if bars.asking {
                bar("person.badge.key", "An assistant wants to work on \(name)") {
                    Button("Deny") { MacLinkHost.shared.answer(document, allow: false) }
                    Button("Allow") { MacLinkHost.shared.answer(document, allow: true) }.keyboardShortcut(.defaultAction)
                }
            }
            if bars.claimed {
                bar("sparkles", "An assistant is working on this document") {
                    Button("Disconnect") { MacLinkHost.shared.revoke(document) }
                }
            } else if bars.allowed {
                bar("checkmark.shield", "Assistants allowed") {
                    Button("Revoke") { MacLinkHost.shared.revoke(document) }
                }
            }
            if document.assistantChanges > 0 {
                let n = document.assistantChanges
                bar("exclamationmark.triangle", "An assistant changed this document (\(n) change\(n == 1 ? "" : "s")); review before posting") {
                    Button("Dismiss") { MacLinkHost.shared.dismissMarker(document) }
                }
            }
        }
    }

    private func bar<Buttons: View>(_ symbol: String, _ text: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(text).lineLimit(2)
                Spacer()
                buttons()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.12))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text)
            Divider()
        }
    }
}
