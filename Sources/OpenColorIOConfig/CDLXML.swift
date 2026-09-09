// SPDX-License-Identifier: BSD-3-Clause
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct NativeXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [NativeXMLNode] = []
    func descendants(named name: String) -> [NativeXMLNode] {
        (self.name == name ? [self] : []) + children.flatMap { $0.descendants(named: name) }
    }
}

final class NativeXMLReader: NSObject, XMLParserDelegate {
    var stack: [NativeXMLNode] = []
    var root: NativeXMLNode?
    var error: Error?
    static func parse(_ source: String) throws -> NativeXMLNode {
        let reader = NativeXMLReader()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let root = reader.root else {
            throw reader.error ?? parser.parserError ?? OCIOConfigError.invalid("invalid XML transform file")
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        stack.append(NativeXMLNode(name: elementName, attributes: attributeDict))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text += string }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if !stack.isEmpty { stack[stack.count - 1].text += String(decoding: CDATABlock, as: UTF8.self) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let node = stack.popLast() else { return }
        if stack.isEmpty { root = node }
        else { stack[stack.count - 1].children.append(node) }
    }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
}

enum CDLXMLFile {
    static func read(_ source: String, cccID: String?) throws -> [OCIONativeFileOperation] {
        let root = try NativeXMLReader.parse(source)
        guard ["ColorCorrection", "ColorCorrectionCollection", "ColorDecisionList"].contains(root.name) else { throw OCIOConfigError.invalid("XML root is not ASC CDL") }
        let corrections = root.descendants(named: "ColorCorrection")
        guard !corrections.isEmpty else { throw OCIOConfigError.invalid("CDL file contains no ColorCorrection") }
        let selected: NativeXMLNode
        if let cccID, !cccID.isEmpty {
            if let named = corrections.first(where: { $0.attributes["id"] == cccID }) { selected = named }
            else if let index = Int(cccID), corrections.indices.contains(index) { selected = corrections[index] }
            else { throw OCIOConfigError.invalid("CDL correction '\(cccID)' not found") }
        } else { selected = corrections[0] }
        var fields: [String: YAMLValue] = ["style": .scalar("asc")]
        for (xml, yaml, count) in [("Slope", "slope", 3), ("Offset", "offset", 3), ("Power", "power", 3), ("Saturation", "sat", 1)] {
            let nodes = selected.descendants(named: xml)
            guard nodes.count <= 1 else { throw OCIOConfigError.invalid("duplicate CDL '\(xml)'") }
            if let node = nodes.first {
                let numbers = try OCIOLUTFile.numbers(node.text.split(whereSeparator: \.isWhitespace).map(String.init), count: count)
                fields[yaml] = count == 1 ? .scalar(String(numbers[0])) : .sequence(numbers.map { .scalar(String($0)) })
            } else if xml != "Saturation" { throw OCIOConfigError.invalid("missing CDL '\(xml)'") }
        }
        return [.transform(try OCIOConfigTransform(yaml: .tagged("CDLTransform", .mapping(fields))))]
    }
}
