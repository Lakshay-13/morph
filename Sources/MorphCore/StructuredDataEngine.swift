import CoreFoundation
import Darwin
import Foundation
import TOML
import Yams

public enum StructuredDataEngine {
    private static let maximumStructuredInputBytes = 10 * 1024 * 1024
    private static let maximumNestedDepth = 128
    private static let maximumTableKeys = 10_000
    private static let maximumArrayLength = 100_000

    public static func convert(input: URL, output: URL) throws {
        let sourceExtension = input.pathExtension.lowercased()
        let targetExtension = output.pathExtension.lowercased()
        let supportedExtensions: Set<String> = ["json", "csv", "tsv", "xml", "yaml", "yml", "toml"]
        guard supportedExtensions.contains(sourceExtension), supportedExtensions.contains(targetExtension) else {
            throw MorphError.unsupportedConversion(sourceExtension, targetExtension)
        }

        let text = try readText(input, extension: sourceExtension)
        let value = try decode(inputText: text, extension: sourceExtension)
        let converted = try encode(value, sourceExtension: sourceExtension, targetExtension: targetExtension)

        do { try converted.write(to: output, options: .atomic) }
        catch { throw MorphError.processFailed("Could not write the converted data: \(error.localizedDescription)") }
    }

    public static func validateGeneratedOutput(_ url: URL, extension fileExtension: String) throws {
        do {
            let text = try readText(url, extension: fileExtension)
            _ = try decode(inputText: text, extension: fileExtension)
        } catch {
            throw MorphError.invalidOutput("The generated \(fileExtension.uppercased()) is not valid: \(error.localizedDescription)")
        }
    }

    private static func readText(_ input: URL, extension fileExtension: String) throws -> String {
        if ["yaml", "yml", "toml"].contains(fileExtension) {
            let size = try fileSizeAtPath(input)
            guard size <= Int64(maximumStructuredInputBytes) else {
                throw MorphError.invalidInput("YAML and TOML inputs must be 10 MB or smaller.")
            }
        }

        do {
            let text = try String(contentsOf: input, encoding: .utf8)
            if ["yaml", "yml", "toml"].contains(fileExtension), text.utf8.count > maximumStructuredInputBytes {
                throw MorphError.invalidInput("YAML and TOML inputs must be 10 MB or smaller.")
            }
            return text
        } catch let error as MorphError {
            throw error
        } catch {
            throw MorphError.invalidInput("The file is not readable UTF-8 text.")
        }
    }

    private static func fileSizeAtPath(_ input: URL) throws -> Int64 {
        let resolvedURL = input.resolvingSymlinksInPath()
        var fileInfo = stat()
        let result = resolvedURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &fileInfo)
        }
        guard result == 0,
              fileInfo.st_size >= 0,
              fileInfo.st_mode & S_IFMT == S_IFREG else {
            throw MorphError.invalidInput("The structured-data input must be a readable regular file.")
        }
        return Int64(fileInfo.st_size)
    }

    private static func decode(inputText text: String, extension fileExtension: String) throws -> DynamicJSONValue {
        do {
            switch fileExtension {
            case "json":
                try validateJSONDepth(text)
                return try JSONDecoder().decode(DynamicJSONValue.self, from: Data(text.utf8))
            case "yaml", "yml":
                return try decodeYAML(text)
            case "toml":
                let decoder = TOMLDecoder()
                decoder.limits = .init(
                    maxInputSize: maximumStructuredInputBytes,
                    maxDepth: maximumNestedDepth,
                    maxTableKeys: maximumTableKeys,
                    maxArrayLength: maximumArrayLength,
                    maxStringLength: 1024 * 1024
                )
                return try decoder.decode(DynamicJSONValue.self, from: text)
            case "csv", "tsv":
                let delimiter: Character = fileExtension == "tsv" ? "\t" : ","
                let rows = try parseDelimited(text, delimiter: delimiter)
                return try records(from: rows)
            case "xml":
                return try decodeXML(text)
            default:
                throw MorphError.unsupportedConversion(fileExtension, "structured data")
            }
        } catch let error as MorphError {
            throw error
        } catch {
            throw MorphError.invalidInput("Could not parse the \(fileExtension.uppercased()) input: \(error.localizedDescription)")
        }
    }

    private static func validateJSONDepth(_ text: String) throws {
        var depth = 0
        var inString = false
        var escaped = false

        for byte in text.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                guard depth <= maximumNestedDepth else {
                    throw MorphError.invalidInput("JSON inputs may not be nested more than 128 levels.")
                }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                if depth < 0 { return }
            }
        }
    }

    private static func encode(
        _ value: DynamicJSONValue,
        sourceExtension: String,
        targetExtension: String
    ) throws -> Data {
        do {
            switch targetExtension {
            case "json":
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                return try encoder.encode(value)
            case "yaml", "yml":
                return Data(try YAMLEncoder().encode(value).utf8)
            case "toml":
                let root = try tomlRoot(value)
                try validateTOMLValue(root)
                let encoder = TOMLEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let text = try encoder.encodeToString(root)
                return Data((text.isEmpty ? "# Empty TOML table\n" : text).utf8)
            case "csv", "tsv":
                let rows = try records(from: value)
                let delimiter: Character = targetExtension == "tsv" ? "\t" : ","
                let header = Array(Set(rows.flatMap(\.keys))).sorted()
                guard !header.isEmpty else {
                    throw MorphError.invalidInput("Delimited output requires at least one record field.")
                }
                var delimitedRows = [header]
                delimitedRows.append(contentsOf: rows.map { row in
                    header.map { scalarString(row[$0]?.foundationValue ?? NSNull()) }
                })
                return Data(serializeDelimited(delimitedRows, delimiter: delimiter).utf8)
            case "xml":
                let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + element(name: "root", value: value.foundationValue) + "\n"
                return Data(xml.utf8)
            default:
                throw MorphError.unsupportedConversion(sourceExtension, targetExtension)
            }
        } catch let error as MorphError {
            throw error
        } catch {
            throw MorphError.invalidOutput("Could not encode \(targetExtension.uppercased()) output: \(error.localizedDescription)")
        }
    }

    private static func decodeYAML(_ text: String) throws -> DynamicJSONValue {
        var documents = try Yams.load_all(yaml: text, yaml12Resolver)
        guard let document = documents.next() else {
            throw MorphError.invalidInput("The YAML document is empty or malformed: \(documents.error?.localizedDescription ?? "no document found")")
        }
        if let error = documents.error {
            throw MorphError.invalidInput("The YAML document is malformed: \(error.localizedDescription)")
        }
        guard documents.next() == nil else {
            throw MorphError.invalidInput("Multi-document YAML files are not supported; convert one document at a time.")
        }
        if let error = documents.error {
            throw MorphError.invalidInput("The YAML document is malformed: \(error.localizedDescription)")
        }
        return try DynamicJSONValue.fromFoundation(document, depth: 0)
    }

    private static let yaml12Resolver: Resolver = {
        let nullPattern = "^(?:~|null|Null|NULL|)$"
        let boolPattern = "^(?:true|True|TRUE|false|False|FALSE)$"
        let intPattern = "^[-+]?(?:0|[1-9][0-9_]*|0x[0-9a-fA-F_]+|0o[0-7_]+|0b[0-1_]+)$"
        let floatPattern = "^(?:[-+]?(?:(?:[0-9][0-9_]*)?\\.[0-9_]+|[0-9][0-9_]*\\.)(?:[eE][-+]?[0-9]+)?|[-+]?[0-9][0-9_]*[eE][-+]?[0-9]+|[-+]?(?:\\.inf|\\.Inf|\\.INF|\\.nan|\\.NaN|\\.NAN))$"
        return try! Resolver.basic
            .appending(.null, nullPattern)
            .appending(.bool, boolPattern)
            .appending(.int, intPattern)
            .appending(.float, floatPattern)
    }()

    private static func decodeXML(_ text: String) throws -> DynamicJSONValue {
        guard let data = text.data(using: .utf8) else {
            throw MorphError.invalidInput("The XML text is not valid UTF-8.")
        }
        let parser = XMLTreeParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldResolveExternalEntities = false
        xmlParser.delegate = parser
        guard xmlParser.parse(), let root = parser.root else {
            throw MorphError.invalidInput("The XML document is malformed.")
        }
        return try DynamicJSONValue.fromFoundation(root.objectValue, depth: 0)
    }

    private static func tomlRoot(_ value: DynamicJSONValue) throws -> DynamicJSONValue {
        switch value {
        case .object:
            return value
        case .array:
            return .object(["records": value])
        default:
            throw MorphError.invalidInput("TOML requires a top-level table. Convert a JSON or YAML object, or an array of records.")
        }
    }

    private static func validateTOMLValue(_ value: DynamicJSONValue) throws {
        switch value {
        case .unsigned(let number) where number > UInt64(Int64.max):
            throw MorphError.invalidInput("TOML integers must fit in the signed 64-bit range.")
        case .object(let values):
            for value in values.values { try validateTOMLValue(value) }
        case .array(let values):
            for value in values { try validateTOMLValue(value) }
        default:
            break
        }
    }

    private static func records(from value: DynamicJSONValue) throws -> [[String: DynamicJSONValue]] {
        let candidate: DynamicJSONValue
        if case .object(let object) = value, let records = object["records"] {
            candidate = records
        } else {
            candidate = value
        }
        guard case .array(let array) = candidate,
              array.allSatisfy({ if case .object = $0 { return true }; return false }) else {
            throw MorphError.invalidInput("CSV or TSV conversion requires an array of objects. TOML inputs should place rows in a top-level 'records' array.")
        }
        return array.compactMap { if case .object(let row) = $0 { return row }; return nil }
    }

    private static func records(from rows: [[String]]) throws -> DynamicJSONValue {
        guard let header = rows.first, !header.isEmpty else { throw MorphError.invalidInput("The delimited file has no header row.") }
        let names = header.enumerated().map { index, name in name.isEmpty ? "column_\(index + 1)" : name }
        guard Set(names).count == names.count else { throw MorphError.invalidInput("The header row contains duplicate column names.") }
        let records = rows.dropFirst().filter { !$0.allSatisfy(\.isEmpty) }.map { row in
            DynamicJSONValue.object(Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
                (name, .string(index < row.count ? row[index] : ""))
            }))
        }
        return .array(records)
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

    private static func scalarString(_ value: Any) -> String {
        if value is NSNull { return "" }
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let nested = String(data: data, encoding: .utf8) { return nested }
        return String(describing: value)
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
