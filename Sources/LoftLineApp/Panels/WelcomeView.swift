import AppKit
import SwiftUI

/// First-run Welcome window: new/open, the sample sign, and the quick-start steps.
struct WelcomeView: View {
    static let windowID = "loftline-welcome"
    @ObservedObject var preferences = PreferencesModel.shared
    @ObservedObject var updates = UpdateController.shared
    @State private var message: String?

    static func show() {
        HostedWindows.show(id: windowID, title: "Welcome to LoftLine", size: CGSize(width: 720, height: 560),
                           resizable: false) { WelcomeView() }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "scissors.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Welcome to LoftLine").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Design parts and make G-code for the Avid PRO6096.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Button { newDocument() } label: { Label("New Document", systemImage: "doc.badge.plus") }
                    .keyboardShortcut("n", modifiers: .command)
                Button { NSDocumentController.shared.openDocument(nil) } label: { Label("Open…", systemImage: "folder") }
                Button { open(SampleProjects.sign) } label: { Label("Open the Sample Sign", systemImage: "star") }
                    .help(SampleProjects.sign.detail)
                Button { HelpNavigator.show(.gettingStarted) } label: { Label("Getting Started Help", systemImage: "questionmark.circle") }
                Spacer()
                Toggle("Show this window when LoftLine starts", isOn: $preferences.prefs.showWelcomeAtLaunch)
                    .font(.callout)
            }
            .buttonStyle(.link)
            .labelStyle(WelcomeLinkLabelStyle())
            .padding(24)
            .frame(width: 290, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.quaternary.opacity(0.4))

            VStack(alignment: .leading, spacing: 12) {
                UpdateBanner(controller: updates)
                Text("Quick start").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                ForEach(Array(SampleProjects.quickStart.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)").font(.headline.monospacedDigit())
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.accentColor.opacity(0.2)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.headline)
                            Text(step.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Step \(i + 1): \(step.title). \(step.detail)")
                }
                Divider()
                Text("More samples").font(.headline)
                ForEach(SampleProjects.all.filter { !$0.isProject }) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.title)
                            // Two lines, not one cut off mid-word ("…a bore, to pra…").
                            Text(s.detail).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Show in Finder") { reveal(s) }
                            .help("Import it with File ▸ Import… in any document")
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(Color.errorText) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 720, height: 560)
    }

    private func newDocument() {
        NSDocumentController.shared.newDocument(nil)
        HostedWindows.close(id: Self.windowID)
    }

    /// Opens a sample as a new untitled copy so the bundled file is never overwritten.
    private func open(_ sample: SampleProjects.Sample) {
        guard let url = SampleProjects.url(for: sample) else {
            message = "The sample \(sample.fileName) was not found."
            return
        }
        do {
            _ = try NSDocumentController.shared.duplicateDocument(withContentsOf: url, copying: true,
                                                                  displayName: sample.title)
            HostedWindows.close(id: Self.windowID)
        } catch {
            // Unbundled builds may not know the .loftline type: open the file itself instead.
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, err in
                if let err { message = "Could not open the sample: \(err.localizedDescription)" }
            }
        }
    }

    private func reveal(_ sample: SampleProjects.Sample) {
        guard let url = SampleProjects.url(for: sample) else {
            message = "The sample \(sample.fileName) was not found."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// A link with its icon in a fixed-width column, so the labels start at the same x whatever the icon's width.
struct WelcomeLinkLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 22, alignment: .center)
            configuration.title
        }
    }
}
