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
    private static let maximumDelimitedColumns = 10_000
    private static let maximumDelimitedCells = 500_000
    private static let maximumStructuredOutputBytes = 20 * 1024 * 1024
    private static let maximumDelimitedOutputBytes = maximumStructuredOutputBytes
    private static let doubledUTF8BOM: [UInt8] = [0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF]

    public static func convert(input: URL, output: URL) throws {
        let sourceExtension = input.pathExtension.lowercased()
        let targetExtension = output.pathExtension.lowercased()
        let supportedExtensions: Set<String> = ["json", "csv", "tsv", "xml", "yaml", "yml", "toml"]
        guard supportedExtensions.contains(sourceExtension), supportedExtensions.contains(targetExtension) else {
            throw MorphError.unsupportedConversion(sourceExtension, targetExtension)
        }

        let text = try readText(input, rejectDoubledUTF8BOM: sourceExtension == "toml")
        let value = try decode(inputText: text, extension: sourceExtension, outputExtension: targetExtension)
        try validateEstimatedOutputSize(value, targetExtension: targetExtension)
        let converted = try encode(value, sourceExtension: sourceExtension, targetExtension: targetExtension)
        guard converted.count <= maximumStructuredOutputBytes else {
            throw MorphError.invalidOutput("Structured-data output may not exceed 20 MB.")
        }

        do { try converted.write(to: output, options: .atomic) }
        catch { throw MorphError.processFailed("Could not write the converted data: \(error.localizedDescription)") }
    }

    public static func validateGeneratedOutput(_ url: URL, extension fileExtension: String) throws {
        do {
            let text = try readText(
                url,
                maximumBytes: maximumStructuredOutputBytes,
                rejectDoubledUTF8BOM: fileExtension == "toml"
            )
            _ = try decode(inputText: text, extension: fileExtension)
        } catch {
            throw MorphError.invalidOutput("The generated \(fileExtension.uppercased()) is not valid: \(error.localizedDescription)")
        }
    }

    /// Rewrites a spreadsheet-generated delimited file using Morph's formula
    /// guard. LibreOffice output is untrusted even when the source document is
    /// otherwise a valid spreadsheet.
    static func sanitizeDelimitedFile(at url: URL) throws {
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "csv" || fileExtension == "tsv" else { return }
        let descriptor = url.path.withCString { open($0, O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw MorphError.invalidOutput("Morph could not safely open the spreadsheet's generated delimited file.")
        }
        defer { close(descriptor) }
        let text = try readText(descriptor: descriptor, maximumBytes: maximumStructuredOutputBytes)
        let delimiter: Character = fileExtension == "tsv" ? "\t" : ","
        let rows = try parseDelimited(text, delimiter: delimiter)
        guard rows.count <= maximumArrayLength else {
            throw MorphError.invalidOutput("Spreadsheet delimited output may not exceed 100,000 rows.")
        }
        var output = ""
        var outputBytes = 0
        var cells = 0
        for row in rows {
            guard row.count <= maximumDelimitedColumns,
                  cells <= maximumDelimitedCells - row.count else {
                throw MorphError.invalidOutput("Spreadsheet delimited output exceeds Morph's safety limits.")
            }
            cells += row.count
            let line = serializeDelimitedRow(row, delimiter: delimiter) + "\n"
            guard outputBytes <= maximumStructuredOutputBytes - line.utf8.count else {
                throw MorphError.invalidOutput("Spreadsheet delimited output may not exceed 20 MB.")
            }
            output.append(contentsOf: line)
            outputBytes += line.utf8.count
        }
        let bytes = Array(output.utf8)
        var openedInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &openedInfo) == 0,
              openedInfo.st_mode & S_IFMT == S_IFREG,
              url.path.withCString({ lstat($0, &pathInfo) }) == 0,
              pathInfo.st_mode & S_IFMT == S_IFREG,
              openedInfo.st_dev == pathInfo.st_dev,
              openedInfo.st_ino == pathInfo.st_ino,
              lseek(descriptor, 0, SEEK_SET) >= 0,
              ftruncate(descriptor, 0) == 0 else {
            throw MorphError.invalidOutput("The spreadsheet output changed before Morph could sanitize it.")
        }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw MorphError.processFailed("Morph could not safely sanitize the spreadsheet's delimited output.")
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw MorphError.processFailed("Morph could not finish sanitizing the spreadsheet's delimited output.")
        }
    }

    private static func readText(
        _ input: URL,
        maximumBytes: Int = maximumStructuredInputBytes,
        rejectDoubledUTF8BOM: Bool = false
    ) throws -> String {
        let descriptor = input.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw MorphError.invalidInput("The structured-data input is not a readable regular file.")
        }
        defer { close(descriptor) }

        return try readText(
            descriptor: descriptor,
            maximumBytes: maximumBytes,
            rejectDoubledUTF8BOM: rejectDoubledUTF8BOM
        )
    }

    private static func readText(
        descriptor: Int32,
        maximumBytes: Int,
        rejectDoubledUTF8BOM: Bool = false
    ) throws -> String {

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG,
              fileInfo.st_size >= 0,
              fileInfo.st_size <= Int64(maximumBytes) else {
            throw MorphError.invalidInput(maximumBytes == maximumStructuredInputBytes
                ? "Structured-data inputs must be regular files no larger than 10 MB."
                : "Structured-data output files must be regular files no larger than 20 MB.")
        }

        var data = Data()
        data.reserveCapacity(Int(fileInfo.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in read(descriptor, bytes.baseAddress, bytes.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw MorphError.invalidInput("The structured-data file could not be read safely.")
            }
            guard count <= maximumBytes - data.count else {
                throw MorphError.invalidInput(maximumBytes == maximumStructuredInputBytes
                    ? "Structured-data inputs must be 10 MB or smaller."
                    : "Structured-data outputs must be 20 MB or smaller.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !rejectDoubledUTF8BOM || !data.starts(with: doubledUTF8BOM) else {
            throw MorphError.invalidInput("TOML inputs may start with at most one UTF-8 byte order mark.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MorphError.invalidInput("The file is not readable UTF-8 text.")
        }
        return text
    }

    private static func decode(
        inputText text: String,
        extension fileExtension: String,
        outputExtension: String? = nil
    ) throws -> DynamicJSONValue {
        do {
            switch fileExtension {
            case "json":
                try validateJSONDepth(text)
                return try JSONDecoder().decode(DynamicJSONValue.self, from: Data(text.utf8))
            case "yaml", "yml":
                return try decodeYAML(text)
            case "toml":
                let decoder = TOMLDecoder()
                decoder.userInfo[dynamicJSONTOMLDateDecodingKey] = true
                decoder.limits = .init(
                    maxInputSize: maximumStructuredInputBytes,
                    maxDepth: maximumNestedDepth,
                    maxTableKeys: maximumTableKeys,
                    maxArrayLength: maximumArrayLength,
                    maxStringLength: 1024 * 1024
                )
                return try decoder.decode(DynamicJSONValue.self, from: Data(text.utf8))
            case "csv", "tsv":
                let delimiter: Character = fileExtension == "tsv" ? "\t" : ","
                let rows = try parseDelimited(text, delimiter: delimiter)
                return try records(from: rows, targetExtension: outputExtension ?? "json")
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
                var headerSet = Set<String>()
                for row in rows {
                    guard row.count <= maximumDelimitedColumns else {
                        throw MorphError.invalidInput("Delimited output may not contain more than 10,000 columns per record.")
                    }
                    for key in row.keys {
                        headerSet.insert(key)
                        guard headerSet.count <= maximumDelimitedColumns else {
                            throw MorphError.invalidInput("Delimited output may not contain more than 10,000 columns.")
                        }
                    }
                }
                let header = headerSet.sorted()
                guard !header.isEmpty else {
                    throw MorphError.invalidInput("Delimited output requires at least one record field.")
                }
                guard rows.count <= maximumArrayLength,
                      header.count <= maximumDelimitedCells / max(1, rows.count + 1) else {
                    throw MorphError.invalidInput("Delimited output would exceed Morph's 500,000-cell limit.")
                }
                var output = serializeDelimitedRow(header, delimiter: delimiter) + "\n"
                var outputBytes = output.utf8.count
                for row in rows {
                    let line = serializeDelimitedRow(header.map { scalarString(row[$0]?.foundationValue ?? NSNull()) }, delimiter: delimiter) + "\n"
                    let lineBytes = line.utf8.count
                    guard outputBytes <= maximumDelimitedOutputBytes - lineBytes else {
                        throw MorphError.invalidOutput("Delimited output may not exceed 20 MB.")
                    }
                    output.append(contentsOf: line)
                    outputBytes += lineBytes
                }
                return Data(output.utf8)
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
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        try validateYAMLStructureBeforeParsing(normalized)
        let resolver = try yaml12Resolver()
        var documents = try Yams.compose_all(yaml: normalized, resolver)
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
        try validateYAMLNode(document)
        return try DynamicJSONValue.fromFoundation(document.any, depth: 0)
    }

    private static func validateYAMLStructureBeforeParsing(_ text: String) throws {
        var flowDepth = 0
        var blockScalarParentIndent: Int?
        var blockScalarRequiredIndent: Int?
        var inSingleQuotedScalar = false
        var inDoubleQuotedScalar = false
        var escaped = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indentation = line.prefix { $0 == " " }.count
            if let parentIndent = blockScalarParentIndent {
                let isBlankLine = line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
                if isBlankLine { continue }
                if indentation > parentIndent {
                    if let requiredIndent = blockScalarRequiredIndent, indentation < requiredIndent {
                        blockScalarParentIndent = nil
                        blockScalarRequiredIndent = nil
                    } else {
                        continue
                    }
                } else {
                    blockScalarParentIndent = nil
                    blockScalarRequiredIndent = nil
                }
            }
            guard indentation <= maximumNestedDepth else {
                throw MorphError.invalidInput("YAML inputs may not be nested more than 128 levels.")
            }
            guard indentation + flowDepth <= maximumNestedDepth else {
                throw MorphError.invalidInput("YAML inputs may not be nested more than 128 levels.")
            }

            let scalars = Array(line.unicodeScalars)
            var structuralMarkers = 0
            var nextBlockScalarRequiredIndent: Int?
            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                if inDoubleQuotedScalar {
                    if escaped {
                        escaped = false
                    } else if scalar == "\\" {
                        escaped = true
                    } else if scalar == "\"" {
                        inDoubleQuotedScalar = false
                    }
                } else if inSingleQuotedScalar {
                    if scalar == "'" {
                        if index + 1 < scalars.count, scalars[index + 1] == "'" {
                            index += 1
                        } else {
                            inSingleQuotedScalar = false
                        }
                    }
                } else if scalar == "#", index == 0 || scalars[index - 1].properties.isWhitespace {
                    break
                } else if scalar == "'" {
                    inSingleQuotedScalar = true
                } else if scalar == "\"" {
                    inDoubleQuotedScalar = true
                } else if flowDepth == 0, (scalar == "|" || scalar == ">"),
                          let requiredIndent = blockScalarHeaderRequiredIndent(in: scalars, at: index, parentIndent: indentation) {
                    nextBlockScalarRequiredIndent = requiredIndent
                } else if scalar == "[" || scalar == "{" {
                    flowDepth += 1
                    guard indentation + flowDepth + structuralMarkers <= maximumNestedDepth else {
                        throw MorphError.invalidInput("YAML inputs may not be nested more than 128 levels.")
                    }
                } else if scalar == "]" || scalar == "}" {
                    flowDepth = max(0, flowDepth - 1)
                } else if scalar == "-",
                          (index == 0 || scalars[index - 1].properties.isWhitespace),
                          index + 1 == scalars.count || scalars[index + 1].properties.isWhitespace {
                    structuralMarkers += 1
                    guard indentation + flowDepth + structuralMarkers <= maximumNestedDepth else {
                        throw MorphError.invalidInput("YAML inputs may not be nested more than 128 levels.")
                    }
                } else if flowDepth == 0, scalar == "?",
                          (index == 0 || scalars[index - 1].properties.isWhitespace),
                          index + 1 == scalars.count || scalars[index + 1].properties.isWhitespace {
                    structuralMarkers += 1
                    guard indentation + flowDepth + structuralMarkers <= maximumNestedDepth else {
                        throw MorphError.invalidInput("YAML inputs may not be nested more than 128 levels.")
                    }
                }
                index += 1
            }
            if let nextBlockScalarRequiredIndent {
                blockScalarParentIndent = indentation
                blockScalarRequiredIndent = nextBlockScalarRequiredIndent
            }
            // YAML quoted scalars may span physical lines. Preserve quote state
            // so bracket-like text on continuation lines is not treated as flow
            // syntax. A trailing escape consumes the line break itself.
            escaped = false
        }
    }

    private static func blockScalarHeaderRequiredIndent(in scalars: [UnicodeScalar], at index: Int, parentIndent: Int) -> Int? {
        let prefix = String(String.UnicodeScalarView(scalars[..<index])).trimmingCharacters(in: .whitespaces)
        guard prefix.isEmpty || prefix.hasSuffix(":") || prefix.hasSuffix("-") else { return nil }
        var cursor = index + 1
        var explicitIndent: Int?
        var hasChompingIndicator = false
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar == "+" || scalar == "-" {
                guard !hasChompingIndicator else { return nil }
                hasChompingIndicator = true
                cursor += 1
            } else if scalar.value >= 0x31 && scalar.value <= 0x39 {
                guard explicitIndent == nil else { return nil }
                explicitIndent = Int(scalar.value - 0x30)
                cursor += 1
            } else {
                break
            }
        }
        if cursor < scalars.count {
            guard scalars[cursor].properties.isWhitespace || scalars[cursor] == "#" else { return nil }
            while cursor < scalars.count, scalars[cursor].properties.isWhitespace { cursor += 1 }
            if cursor < scalars.count, scalars[cursor] != "#" { return nil }
        }
        return explicitIndent.map { parentIndent + $0 } ?? parentIndent + 1
    }

    private static func validateYAMLNode(_ root: Node) throws {
        var pending: [(node: Node, depth: Int)] = [(root, 0)]
        var visitedNodes = 0
        var expandedScalarBytes = 0

        while let current = pending.popLast() {
            visitedNodes += 1
            guard visitedNodes <= 100_000 else {
                throw MorphError.invalidInput("The YAML input expands to more than 100,000 values.")
            }
            guard current.depth <= maximumNestedDepth else {
                throw MorphError.invalidInput("YAML inputs may not be nested more than 128 levels.")
            }

            switch current.node {
            case .scalar(let scalar):
                expandedScalarBytes += scalar.string.utf8.count
                guard expandedScalarBytes <= maximumStructuredInputBytes * 2 else {
                    throw MorphError.invalidInput("YAML aliases expand to too much text to convert safely.")
                }
            case .sequence(let sequence):
                guard sequence.count <= maximumArrayLength else {
                    throw MorphError.invalidInput("A YAML sequence may not contain more than 100,000 values.")
                }
                for child in sequence { pending.append((child, current.depth + 1)) }
            case .mapping(let mapping):
                guard mapping.count <= maximumTableKeys else {
                    throw MorphError.invalidInput("A YAML mapping may not contain more than 10,000 keys.")
                }
                for (key, value) in mapping {
                    guard case .scalar(let scalar) = key else {
                        throw MorphError.invalidInput("YAML mapping keys must be scalar strings.")
                    }
                    guard scalar.string != "<<" else {
                        throw MorphError.invalidInput("YAML merge keys are not supported for safe conversion.")
                    }
                    pending.append((key, current.depth + 1))
                    pending.append((value, current.depth + 1))
                }
            case .alias:
                throw MorphError.invalidInput("Unresolved YAML aliases are not supported.")
            }
        }
    }

    private static func yaml12Resolver() throws -> Resolver {
        let nullPattern = "^(?:~|null|Null|NULL|)$"
        let boolPattern = "^(?:true|True|TRUE|false|False|FALSE)$"
        let intPattern = "^[-+]?(?:0|[1-9][0-9_]*|0x[0-9a-fA-F_]+|0o[0-7_]+|0b[0-1_]+)$"
        let floatPattern = "^(?:[-+]?(?:(?:[0-9][0-9_]*)?\\.[0-9_]+|[0-9][0-9_]*\\.)(?:[eE][-+]?[0-9]+)?|[-+]?[0-9][0-9_]*[eE][-+]?[0-9]+|[-+]?(?:\\.inf|\\.Inf|\\.INF|\\.nan|\\.NaN|\\.NAN))$"
        return try Resolver.basic
            .appending(.null, nullPattern)
            .appending(.bool, boolPattern)
            .appending(.int, intPattern)
            .appending(.float, floatPattern)
    }

    private static func decodeXML(_ text: String) throws -> DynamicJSONValue {
        guard let data = text.data(using: .utf8) else {
            throw MorphError.invalidInput("The XML text is not valid UTF-8.")
        }
        let parser = XMLTreeParser(
            maximumNodeCount: maximumArrayLength,
            maximumDepth: maximumNestedDepth,
            maximumTableKeys: maximumTableKeys,
            maximumTextBytes: maximumStructuredInputBytes
        )
        let xmlParser = XMLParser(data: data)
        xmlParser.shouldResolveExternalEntities = false
        xmlParser.delegate = parser
        guard xmlParser.parse(), let root = parser.root else {
            if let limitError = parser.limitError {
                throw MorphError.invalidInput(limitError)
            }
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
        guard case .array(let array) = candidate else {
            throw MorphError.invalidInput("CSV or TSV conversion requires an array of objects. TOML inputs should place rows in a top-level 'records' array.")
        }
        guard array.count <= maximumArrayLength else {
            throw MorphError.invalidInput("Delimited output may not contain more than 100,000 records.")
        }

        var columns = Set<String>()
        for record in array {
            guard case .object(let row) = record else {
                throw MorphError.invalidInput("CSV or TSV conversion requires an array of objects. TOML inputs should place rows in a top-level 'records' array.")
            }
            guard row.count <= maximumDelimitedColumns else {
                throw MorphError.invalidInput("Delimited output may not contain more than 10,000 columns per record.")
            }
            columns.formUnion(row.keys)
            guard columns.count <= maximumDelimitedColumns else {
                throw MorphError.invalidInput("Delimited output may not contain more than 10,000 columns.")
            }
        }
        guard columns.count <= maximumDelimitedCells / max(1, array.count + 1) else {
            throw MorphError.invalidInput("Delimited output would exceed Morph's 500,000-cell limit.")
        }
        return array.map { record in
            guard case .object(let row) = record else { return [:] }
            return row
        }
    }

    private static func records(from rows: [[String]], targetExtension: String) throws -> DynamicJSONValue {
        guard let header = rows.first, !header.isEmpty else { throw MorphError.invalidInput("The delimited file has no header row.") }
        guard rows.count <= maximumArrayLength,
              header.count <= maximumDelimitedColumns else {
            throw MorphError.invalidInput("CSV or TSV inputs may not contain more than 100,000 rows or 10,000 columns.")
        }
        let names = header.enumerated().map { index, name in name.isEmpty ? "column_\(index + 1)" : name }
        guard Set(names).count == names.count else { throw MorphError.invalidInput("The header row contains duplicate column names.") }
        let dataRows = rows.dropFirst()
        guard dataRows.allSatisfy({ $0.count <= names.count }) else {
            throw MorphError.invalidInput("A CSV or TSV row contains more fields than the header.")
        }
        guard dataRows.count <= maximumDelimitedCells / max(1, names.count) else {
            throw MorphError.invalidInput("CSV or TSV expansion would exceed Morph's 500,000-cell limit.")
        }
        var estimatedBytes = 32
        if targetExtension == "csv" || targetExtension == "tsv" {
            let delimiter: UInt8 = targetExtension == "tsv" ? 0x09 : 0x2C
            estimatedBytes = estimateDelimitedRow(names, delimiter: delimiter)
            for row in dataRows {
                let fields = names.enumerated().map { index, _ in index < row.count ? row[index] : "" }
                estimatedBytes = addOutputEstimate(estimatedBytes, estimateDelimitedRow(fields, delimiter: delimiter))
                guard estimatedBytes <= maximumStructuredOutputBytes else {
                    throw MorphError.invalidInput("CSV or TSV expansion would exceed Morph's 20 MB structured-data output limit.")
                }
            }
        } else {
            for row in dataRows {
                estimatedBytes = addOutputEstimate(estimatedBytes, 64)
                for (index, name) in names.enumerated() {
                    estimatedBytes = addOutputEstimate(estimatedBytes, escapedStringEstimate(name, targetExtension: targetExtension))
                    estimatedBytes = addOutputEstimate(estimatedBytes, 64)
                    estimatedBytes = addOutputEstimate(estimatedBytes, escapedStringEstimate(index < row.count ? row[index] : "", targetExtension: targetExtension))
                    guard estimatedBytes <= maximumStructuredOutputBytes else {
                        throw MorphError.invalidInput("CSV or TSV expansion would exceed Morph's 20 MB structured-data output limit.")
                    }
                }
            }
        }
        let records = dataRows.map { row in
            DynamicJSONValue.object(Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
                (name, .string(index < row.count ? row[index] : ""))
            }))
        }
        return .array(records)
    }

    private static func validateEstimatedOutputSize(_ value: DynamicJSONValue, targetExtension: String) throws {
        if targetExtension == "csv" || targetExtension == "tsv" {
            // Delimited serialization enforces its exact byte limit while appending rows.
            // A generic object/array estimate includes per-value overhead and can reject
            // valid sparse CSV/TSV output that is far below the serialized-size limit.
            return
        }
        guard estimateOutputBytes(value, depth: 0, targetExtension: targetExtension) <= maximumStructuredOutputBytes else {
            throw MorphError.invalidInput("Structured-data expansion would exceed Morph's 20 MB output limit.")
        }
    }

    private static func estimateOutputBytes(_ value: DynamicJSONValue, depth: Int, targetExtension: String) -> Int {
        if targetExtension == "xml" {
            return estimateXMLElementBytes(name: "root", value: value, depth: depth)
        }
        guard depth <= maximumNestedDepth else { return maximumStructuredOutputBytes + 1 }
        switch value {
        case .object(let values):
            var total = 32
            for (key, child) in values {
                total = addOutputEstimate(total, escapedStringEstimate(key, targetExtension: targetExtension))
                total = addOutputEstimate(total, 64 + (depth + 1) * 2)
                total = addOutputEstimate(total, estimateOutputBytes(child, depth: depth + 1, targetExtension: targetExtension))
                if total > maximumStructuredOutputBytes { return maximumStructuredOutputBytes + 1 }
            }
            return total
        case .array(let values):
            var total = 32
            for child in values {
                total = addOutputEstimate(total, 64 + (depth + 1) * 2)
                total = addOutputEstimate(total, estimateOutputBytes(child, depth: depth + 1, targetExtension: targetExtension))
                if total > maximumStructuredOutputBytes { return maximumStructuredOutputBytes + 1 }
            }
            return total
        case .string(let string):
            return escapedStringEstimate(string, targetExtension: targetExtension)
        case .integer(let value):
            return String(value).utf8.count + 64
        case .unsigned(let value):
            return String(value).utf8.count + 64
        case .floating(let value):
            return String(value).utf8.count + 64
        case .boolean, .null:
            return 64
        }
    }

    private static func estimateXMLElementBytes(name: String, value: DynamicJSONValue, depth: Int) -> Int {
        guard depth <= maximumNestedDepth else { return maximumStructuredOutputBytes + 1 }
        let safeName = xmlName(name)
        let tagBytes = 5 + safeName.utf8.count * 2
        var total = tagBytes
        switch value {
        case .object(let values):
            for key in values.keys.sorted() {
                total = addOutputEstimate(total, estimateXMLElementBytes(name: key, value: values[key]!, depth: depth + 1))
                if total > maximumStructuredOutputBytes { return maximumStructuredOutputBytes + 1 }
            }
        case .array(let values):
            for child in values {
                total = addOutputEstimate(total, estimateXMLElementBytes(name: "item", value: child, depth: depth + 1))
                if total > maximumStructuredOutputBytes { return maximumStructuredOutputBytes + 1 }
            }
        default:
            total = addOutputEstimate(total, xmlTextBytes(scalarString(value.foundationValue)))
        }
        if depth == 0 {
            total = addOutputEstimate(total, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n".utf8.count + 1)
        }
        return total
    }

    private static func escapedStringEstimate(_ string: String, targetExtension: String) -> Int {
        switch targetExtension {
        case "json":
            return jsonStringBytes(string)
        case "xml":
            return xmlTextBytes(string)
        case "csv":
            return delimitedFieldBytes(string, delimiter: 0x2C)
        case "tsv":
            return delimitedFieldBytes(string, delimiter: 0x09)
        default:
            let byteCount = string.utf8.count
            guard byteCount <= (maximumStructuredOutputBytes - 16) / 6 else { return maximumStructuredOutputBytes + 1 }
            return byteCount * 6 + 16
        }
    }

    private static func jsonStringBytes(_ string: String) -> Int {
        var total = 2
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x2F, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D:
                total = addOutputEstimate(total, 2)
            case 0..<0x20, 0x2028, 0x2029:
                total = addOutputEstimate(total, 6)
            default:
                total = addOutputEstimate(total, scalar.utf8.count)
            }
            if total > maximumStructuredOutputBytes { return maximumStructuredOutputBytes + 1 }
        }
        return total
    }

    private static func xmlTextBytes(_ string: String) -> Int {
        var total = 0
        for scalar in string.unicodeScalars {
            let count: Int
            switch scalar.value {
            case 0x26: count = 5
            case 0x3C, 0x3E: count = 4
            case 0x22, 0x27: count = 6
            default: count = scalar.utf8.count
            }
            total = addOutputEstimate(total, count)
            if total > maximumStructuredOutputBytes { return maximumStructuredOutputBytes + 1 }
        }
        return total
    }

    private static func delimitedRowBytes(_ fields: [String], delimiter: UInt8) -> Int {
        var total = 1
        for (index, field) in fields.enumerated() {
            if index > 0 { total = addOutputEstimate(total, 1) }
            total = addOutputEstimate(total, delimitedFieldBytes(field, delimiter: delimiter))
        }
        return total
    }

    private static func delimitedFieldBytes(_ field: String, delimiter: UInt8) -> Int {
        let bytes = field.utf8
        var quoteCount = 0
        var requiresQuotes = false
        for byte in bytes {
            if byte == delimiter || byte == 0x22 || byte == 0x0A || byte == 0x0D { requiresQuotes = true }
            if byte == 0x22 { quoteCount += 1 }
        }
        return bytes.count + (requiresQuotes ? quoteCount + 2 : 0)
    }

    private static func estimateDelimitedRow(_ fields: [String], delimiter: UInt8) -> Int {
        delimitedRowBytes(fields, delimiter: delimiter)
    }

    private static func addOutputEstimate(_ current: Int, _ addition: Int) -> Int {
        guard current <= maximumStructuredOutputBytes,
              addition <= maximumStructuredOutputBytes - current else {
            return maximumStructuredOutputBytes + 1
        }
        return current + addition
    }

    private static func parseDelimited(_ text: String, delimiter: Character) throws -> [[String]] {
        let bytes = Array(text.utf8)
        let delimiterByte = delimiter.asciiValue!
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var afterQuote = false
        var rowWasExplicit = false
        var index = 0
        var totalCells = 0

        func appendField() throws {
            guard row.count < maximumDelimitedColumns, totalCells < maximumDelimitedCells else {
                throw MorphError.invalidInput("CSV or TSV inputs may not exceed 10,000 columns or 500,000 cells.")
            }
            row.append(String(decoding: field, as: UTF8.self))
            totalCells += 1
            field.removeAll(keepingCapacity: true)
        }

        func appendRowIfExplicit() throws {
            if rowWasExplicit {
                guard rows.count < maximumArrayLength else {
                    throw MorphError.invalidInput("A CSV or TSV file may not contain more than 100,000 rows.")
                }
                rows.append(row)
            }
            row.removeAll(keepingCapacity: true)
            rowWasExplicit = false
        }

        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if byte == 0x22 {
                    if index + 1 < bytes.count && bytes[index + 1] == 0x22 {
                        field.append(0x22)
                        index += 1
                    } else {
                        quoted = false
                        afterQuote = true
                    }
                } else {
                    field.append(byte)
                }
            } else if afterQuote {
                if byte == delimiterByte {
                    rowWasExplicit = true
                    try appendField()
                    afterQuote = false
                } else if byte == 0x0A || byte == 0x0D {
                    try appendField()
                    afterQuote = false
                    try appendRowIfExplicit()
                    if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
                } else {
                    throw MorphError.invalidInput("A quoted CSV or TSV field has unexpected characters after its closing quote.")
                }
            } else if byte == 0x22 && field.isEmpty {
                rowWasExplicit = true
                quoted = true
            } else if byte == delimiterByte {
                rowWasExplicit = true
                try appendField()
            } else if byte == 0x0A || byte == 0x0D {
                try appendField()
                try appendRowIfExplicit()
                if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 1 }
            } else {
                rowWasExplicit = true
                field.append(byte)
            }
            index += 1
        }
        if quoted { throw MorphError.invalidInput("A quoted field is not closed.") }
        if !field.isEmpty || !row.isEmpty || afterQuote || rowWasExplicit {
            try appendField()
            try appendRowIfExplicit()
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
        if fields.count == 1, fields[0].isEmpty {
            // A bare newline is a blank line to the parser, not an explicit
            // one-column record with an empty value.
            return "\"\""
        }
        return fields.map { sourceField in
            let field = spreadsheetSafeField(sourceField)
            let requiresDelimiterQuote = delimiter.asciiValue.map { field.utf8.contains($0) } ?? false
            let requiresQuoteEscape = field.unicodeScalars.contains { $0.value == 0x22 }
            let hasNewlineScalar = field.unicodeScalars.contains { $0.value == 0x0A || $0.value == 0x0D }
            if requiresDelimiterQuote || requiresQuoteEscape || hasNewlineScalar {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }.joined(separator: String(delimiter))
    }

    private static func spreadsheetSafeField(_ field: String) -> String {
        let scalars = Array(field.unicodeScalars)
        let startsWithControl = scalars.first.map { $0.value == 0x09 || $0.value == 0x0D } ?? false
        guard let firstNonWhitespace = scalars.firstIndex(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && $0.properties.generalCategory != .format
        }) else { return startsWithControl ? "'" + field : field }
        let first = scalars[firstNonWhitespace]
        let beginsWithFormula = first == "="
            || (first == "+" && !isSafePositiveLiteral(field))
            || (first == "@" && !isSafeAtPrefixedLiteral(field))
        let isFiniteNegativeNumber = Double(field.trimmingCharacters(in: .whitespacesAndNewlines))?.isFinite == true
            && first == "-"
        let beginsWithNonNumericMinus = first == "-" && !isFiniteNegativeNumber
        return startsWithControl || beginsWithFormula || beginsWithNonNumericMinus ? "'" + field : field
    }

    private static func isSafePositiveLiteral(_ field: String) -> Bool {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed), number.isFinite { return true }
        return trimmed.range(of: #"^\+[0-9][0-9 ().-]*$"#, options: .regularExpression) != nil
    }

    private static func isSafeAtPrefixedLiteral(_ field: String) -> Bool {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^@[A-Za-z]{1,3}\$?[0-9]+(?::[A-Za-z]{1,3}\$?[0-9]+)?$"#, options: .regularExpression) != nil {
            return false
        }
        return trimmed.range(of: #"^@[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil
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
    private var uniqueChildNames = Set<String>()

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func registerChildName(_ name: String, maximumKeys: Int) -> Bool {
        uniqueChildNames.insert(name)
        return uniqueChildNames.count + (attributes.isEmpty ? 0 : 1) <= maximumKeys
    }

    func exceedsObjectKeyLimit(_ maximumKeys: Int) -> Bool {
        uniqueChildNames.count
            + (attributes.isEmpty ? 0 : 1)
            + (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
            > maximumKeys
    }

    var hasReservedFieldConflict: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText && uniqueChildNames.contains("_text"))
            || (!attributes.isEmpty && uniqueChildNames.contains("@attributes"))
    }

    var objectValue: Any {
        if children.isEmpty && attributes.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [String: Any] = [:]
        if !attributes.isEmpty { result["@attributes"] = attributes }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result["_text"] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var groupedChildren: [String: XMLChildValues] = [:]
        for child in children {
            let value = child.objectValue
            if let existing = groupedChildren[child.name] { existing.values.append(value) }
            else { groupedChildren[child.name] = XMLChildValues(value) }
        }
        for (name, grouped) in groupedChildren {
            result[name] = grouped.values.count == 1 ? grouped.values[0] : grouped.values
        }
        return result
    }
}

private final class XMLChildValues {
    var values: [Any]
    init(_ firstValue: Any) { values = [firstValue] }
}

private final class XMLTreeParser: NSObject, XMLParserDelegate {
    private let maximumNodeCount: Int
    private let maximumDepth: Int
    private let maximumTableKeys: Int
    private let maximumTextBytes: Int
    private var stack: [XMLNode] = []
    private var nodeCount = 0
    private var textBytes = 0
    var root: XMLNode?
    private(set) var parseError: Error?
    private(set) var limitError: String?

    init(maximumNodeCount: Int, maximumDepth: Int, maximumTableKeys: Int, maximumTextBytes: Int) {
        self.maximumNodeCount = maximumNodeCount
        self.maximumDepth = maximumDepth
        self.maximumTableKeys = maximumTableKeys
        self.maximumTextBytes = maximumTextBytes
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard limitError == nil else { return }
        guard stack.count < maximumDepth else {
            reject(parser, message: "XML inputs may not be nested more than 128 levels.")
            return
        }
        nodeCount += 1
        guard nodeCount <= maximumNodeCount else {
            reject(parser, message: "XML inputs may not contain more than 100,000 elements.")
            return
        }
        guard attributeDict.count <= maximumTableKeys else {
            reject(parser, message: "An XML element may not contain more than 10,000 attributes.")
            return
        }
        let node = XMLNode(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last {
            guard parent.registerChildName(node.name, maximumKeys: maximumTableKeys) else {
                reject(parser, message: "An XML element may not contain more than 10,000 child names.")
                return
            }
            parent.children.append(node)
        }
        else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            reject(parser, message: "XML CDATA must contain valid UTF-8 text.")
            return
        }
        appendText(text, parser: parser)
    }

    private func appendText(_ string: String, parser: XMLParser) {
        guard limitError == nil, let current = stack.last else { return }
        let additionalBytes = string.utf8.count
        guard additionalBytes <= maximumTextBytes - textBytes else {
            reject(parser, message: "XML text may not exceed 10 MB.")
            return
        }
        textBytes += additionalBytes
        current.text.append(string)
    }

    private func reject(_ parser: XMLParser, message: String) {
        guard limitError == nil else { return }
        limitError = message
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let current = stack.last else { return }
        guard !current.hasReservedFieldConflict else {
            reject(parser, message: "An XML element cannot combine text or attributes with child elements named '_text' or '@attributes'.")
            return
        }
        guard !current.exceedsObjectKeyLimit(maximumTableKeys) else {
            reject(parser, message: "An XML element may not contain more than 10,000 object fields.")
            return
        }
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { self.parseError = parseError }
}
