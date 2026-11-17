import Foundation

public enum StructuredDataEngine {
    public static func convert(input: URL, output: URL) throws {
        let sourceExtension = input.pathExtension.lowercased()
        let targetExtension = output.pathExtension.lowercased()
        let text: String
        do { text = try String(contentsOf: input, encoding: .utf8) }
        catch { throw MorphError.invalidInput("The file is not readable UTF-8 text.") }

        let converted: Data
        switch (sourceExtension, targetExtension) {
        case ("json", "csv"):
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let rows = try records(from: value)
            converted = Data(serializeCSV(rows).utf8)
        case ("csv", "json"), ("tsv", "json"):
            let delimiter: Character = sourceExtension == "tsv" ? "\t" : ","
            let rows = try parseDelimited(text, delimiter: delimiter)
            converted = try JSONSerialization.data(withJSONObject: records(from: rows), options: [.prettyPrinted, .sortedKeys])
        case ("json", "xml"):
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + element(name: "root", value: value) + "\n"
            converted = Data(xml.utf8)
        case ("xml", "json"):
            guard let data = text.data(using: .utf8) else { throw MorphError.invalidInput("The XML text is not valid UTF-8.") }
            let parser = XMLTreeParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.shouldResolveExternalEntities = false
            xmlParser.delegate = parser
            guard xmlParser.parse(), let root = parser.root else { throw MorphError.invalidInput("The XML document is malformed.") }
            converted = try JSONSerialization.data(withJSONObject: root.objectValue, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        case ("csv", "tsv"), ("tsv", "csv"):
            let sourceDelimiter: Character = sourceExtension == "tsv" ? "\t" : ","
            let targetDelimiter: Character = targetExtension == "tsv" ? "\t" : ","
            let rows = try parseDelimited(text, delimiter: sourceDelimiter)
            converted = Data(serializeDelimited(rows, delimiter: targetDelimiter).utf8)
        default:
            throw MorphError.unsupportedConversion(sourceExtension, targetExtension)
        }

        do { try converted.write(to: output, options: .atomic) }
        catch { throw MorphError.processFailed("Could not write the converted data: \(error.localizedDescription)") }
    }

    private static func records(from value: Any) throws -> [[String: Any]] {
        guard let array = value as? [Any],
              array.allSatisfy({ $0 is [String: Any] }) else {
            throw MorphError.invalidInput("CSV conversion requires a JSON array of objects.")
        }
        return array.compactMap { $0 as? [String: Any] }
    }

    private static func records(from rows: [[String]]) throws -> [[String: String]] {
        guard let header = rows.first, !header.isEmpty else { throw MorphError.invalidInput("The delimited file has no header row.") }
        let names = header.enumerated().map { index, name in name.isEmpty ? "column_\(index + 1)" : name }
        guard Set(names).count == names.count else { throw MorphError.invalidInput("The header row contains duplicate column names.") }
        return rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { row in
            Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
                (name, index < row.count ? row[index] : "")
            })
        }
    }

    private static func serializeCSV(_ rows: [[String: Any]]) -> String {
        let headers = Array(Set(rows.flatMap(\.keys))).sorted()
        guard !headers.isEmpty else { return "" }
        var lines = [serializeDelimitedRow(headers, delimiter: ",")]
        for row in rows {
            lines.append(serializeDelimitedRow(headers.map { scalarString(row[$0] ?? NSNull()) }, delimiter: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func scalarString(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let nested = String(data: data, encoding: .utf8) { return nested }
        return String(describing: value)
    }

    private static func parseDelimited(_ text: String, delimiter: Character) throws -> [[String]] {
        let characters = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == delimiter {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r" {
                row.append(field)
                field = ""
                if !row.allSatisfy(\.isEmpty) { rows.append(row) }
                row = []
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else {
                field.append(character)
            }
            index += 1
        }
        if quoted { throw MorphError.invalidInput("A quoted field is not closed.") }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !row.allSatisfy(\.isEmpty) { rows.append(row) }
        }
        return rows
    }

    private static func serializeCSV(_ rows: [[String]]) -> String {
        serializeDelimited(rows, delimiter: ",")
    }

    private static func serializeDelimited(_ rows: [[String]], delimiter: Character) -> String {
        rows.map { serializeDelimitedRow($0, delimiter: delimiter) }.joined(separator: "\n") + "\n"
    }

    private static func serializeDelimitedRow(_ fields: [String], delimiter: Character) -> String {
        fields.map { field in
            if field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: String(delimiter))
    }

    private static func element(name: String, value: Any) -> String {
        let safeName = xmlName(name)
        let body: String
        if let object = value as? [String: Any] {
            body = object.keys.sorted().map { element(name: $0, value: object[$0]!) }.joined()
        } else if let array = value as? [Any] {
            body = array.map { element(name: "item", value: $0) }.joined()
        } else {
            body = xmlEscape(scalarString(value))
        }
        return "<\(safeName)>\(body)</\(safeName)>"
    }

    private static func xmlName(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        guard let first = mapped.unicodeScalars.first,
              CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_:").contains(first) else {
            return "field_" + mapped
        }
        return mapped.isEmpty ? "field" : mapped
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var objectValue: Any {
        if children.isEmpty && attributes.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [String: Any] = [:]
        if !attributes.isEmpty { result["@attributes"] = attributes }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result["_text"] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for child in children {
            let value = child.objectValue
            if let existing = result[child.name] {
                if var list = existing as? [Any] { list.append(value); result[child.name] = list }
                else { result[child.name] = [existing, value] }
            } else {
                result[child.name] = value
            }
        }
        return result
    }
}

private final class XMLTreeParser: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    var root: XMLNode?
    var parseError: Error?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) }
        else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { self.parseError = parseError }
}
