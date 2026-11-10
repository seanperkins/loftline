import Foundation

/// One tool an assistant can call: its name, what it does, the JSON Schema of its arguments, and the code that runs it.
public struct AssistantTool {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]
    public let call: ([String: Any]) throws -> ToolOutput

    public init(name: String, description: String, inputSchema: [String: Any], call: @escaping ([String: Any]) throws -> ToolOutput) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.call = call
    }
}

/// What a tool answers: text (a summary line, then details), and for `preview` a PNG.
public struct ToolOutput {
    public var text: String
    public var image: Data?

    public init(text: String, image: Data? = nil) { self.text = text; self.image = image }
}
