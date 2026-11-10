import Foundation
import LoftLineKit

/// help: LoftLine's own help topics, so an assistant can look up what a setting means.
enum HelpTool {
    static func all() -> [AssistantTool] {
        [AssistantTool(
            name: "help",
            description: "LoftLine's help: with no topic, the list of topics; with a topic id, its text (what each setting of a toolpath "
                + "or Job Setup means). The \"assistant\" topic is what the user was told about connecting an assistant.",
            inputSchema: Schema.object(["topic": Schema.string("A topic id from the list.")])) { raw in
                guard let id = Args(raw).string("topic") else {
                    let topics = HelpTopic.allCases.map { ["id": $0.rawValue, "title": $0.title] }
                    return Reply.output("\(topics.count) help topics.", ["topics": topics])
                }
                guard let topic = HelpTopic(rawValue: id) else { throw ToolError("No help topic \"\(id)\"; call help with no topic for the list.") }
                let related = topic.related.map(\.rawValue).joined(separator: ", ")
                return ToolOutput(text: "# \(topic.title)\n\n\(topic.body)" + (related.isEmpty ? "" : "\n\nRelated: \(related)"))
            }]
    }
}
