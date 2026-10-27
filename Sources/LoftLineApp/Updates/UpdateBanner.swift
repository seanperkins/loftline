import SwiftUI

/// A line in the Welcome window while an update is waiting for the user or about to install.
struct UpdateBanner: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        if controller.state.offersAttention {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(message).font(.callout)
                Spacer()
                Button("View") { UpdateWindow.show() }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }

    private var message: String {
        switch controller.state {
        case .available(let entry), .readyToInstall(let entry): return "LoftLine \(entry.version) is available"
        case .installPending(let relaunch): return relaunch ? "Restarting to install an update" : "An update installs when you quit"
        default: return ""
        }
    }
}
