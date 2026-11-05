import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimal XML element tree for SVG import (namespace prefixes stripped from element names).
final class SVGNode {
    let name: String
    let attributes: [String: String]
    var children: [SVGNode] = []
    weak var parent: SVGNode?

    init(name: String, attributes: [String: String]) {
        self.name = name; self.attributes = attributes
    }

    subscript(_ key: String) -> String? { attributes[key] }

    /// Attribute or same-named inline style property (style wins, per CSS).
    func property(_ key: String) -> String? {
        SVGAttributes.style(attributes["style"])[key] ?? attributes[key]
    }

    var id: String? { attributes["id"] }

    /// Character data of a "#text" child (text content is kept in document order).
    var data: String { attributes["data"] ?? "" }

    /// Property set on this element or inherited from an ancestor (font-family, font-size…).
    func inherited(_ key: String) -> String? {
        var n: SVGNode? = self
        while let cur = n {
            if let v = cur.property(key), v != "inherit" { return v }
            n = cur.parent
        }
        return nil
    }

    func forEach(_ body: (SVGNode) -> Void) {
        body(self)
        for c in children { c.forEach(body) }
    }

    static func parse(_ data: Data) throws -> SVGNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            let msg = parser.parserError.map { "\($0.localizedDescription)" } ?? "no root element"
            throw LoftLineIOError.malformed("SVG: \(msg)")
        }
        guard root.name == "svg" else { throw LoftLineIOError.malformed("SVG: root element is <\(root.name)>") }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: SVGNode?
        var stack: [SVGNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let node = SVGNode(name: local, attributes: attributeDict)
            if let top = stack.last { node.parent = top; top.children.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let top = stack.last, top.name == "text" || top.name == "tspan" || top.name == "textPath" else { return }
            if let last = top.children.last, last.name == "#text" {
                let merged = SVGNode(name: "#text", attributes: ["data": last.data + string])
                merged.parent = top
                top.children[top.children.count - 1] = merged
            } else {
                let node = SVGNode(name: "#text", attributes: ["data": string])
                node.parent = top
                top.children.append(node)
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }
    }
}
