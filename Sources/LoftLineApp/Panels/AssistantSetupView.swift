import AppKit
import LoftLineKit
import LoftLineMCP
import SwiftUI

/// Help > Connect an AI Assistant…: where the bundled MCP server is, the settings to paste into an assistant, and the folders it
/// may use. Nothing here writes an assistant's own settings (MCP spec, "Setup for users").
struct AssistantSetupView: View {
    static let windowID = "assistant-setup"
    static let title = "Connect an AI Assistant"

    static func show() {
        HostedWindows.show(id: windowID, title: title, size: CGSize(width: 640, height: 760)) { AssistantSetupView() }
    }

    @State private var settings = AssistantSettings.load()
    @State private var copied: String?
    private let serverPath = AssistantSetup.serverPath(besideExecutable: Bundle.main.executableURL ?? URL(fileURLWithPath: "/"))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect an AI Assistant").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("An AI assistant such as Claude can open, edit, check and post LoftLine projects through LoftLine's MCP server. "
                     + "Add it to the assistant with one of the settings below. LoftLine checks every program as it checks yours and "
                     + "never writes one with an error.")
                    .fixedSize(horizontal: false, vertical: true)
                block(title: "The server", text: serverPath, copyLabel: "Copy Path")
                block(title: "Claude Desktop and most assistants (their mcpServers setting)",
                      text: AssistantSetup.config(serverPath: serverPath), copyLabel: "Copy Settings")
                block(title: "Claude Code (paste into a terminal)", text: AssistantSetup.claudeCodeLine(serverPath: serverPath),
                      copyLabel: "Copy Command")
                folders
                Button("About connecting an assistant…") { HelpNavigator.show(.assistant) }
                    .buttonStyle(.link)
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private func block(title: String, text: String, copyLabel: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            Button(copied == title ? "Copied" : copyLabel) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = title
            }
            .accessibilityLabel("\(copyLabel): \(title)")
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folders the assistant may use").font(.headline)
            Text("It reads and writes files only here.").foregroundStyle(.secondary)
            ForEach(settings.allowedFolders, id: \.self) { folder in
                HStack {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(folder).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { change { $0.allowedFolders.removeAll { $0 == folder } } }
                        .accessibilityLabel("Remove \(folder)")
                }
            }
            if settings.allowedFolders.isEmpty {
                Text("No folders: the assistant can't open or save anything.").foregroundStyle(.secondary)
            }
            Button("Add Folder…") { addFolder() }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Allow"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        change { s in if !s.allowedFolders.contains(url.path) { s.allowedFolders.append(url.path) } }
    }

    private func change(_ edit: (inout AssistantSettings) -> Void) {
        var s = settings
        edit(&s)
        do {
            try s.save()
            settings = s
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
