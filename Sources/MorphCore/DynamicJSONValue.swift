import CoreFoundation
import Foundation
import TOML

let dynamicJSONTOMLDateDecodingKey = CodingUserInfoKey(rawValue: "com.lakshaychawla.Morph.decodeTOMLDates")!

enum DynamicJSONValue: Codable, Equatable {
    case object([String: DynamicJSONValue])
    case array([DynamicJSONValue])
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)
    case floating(Double)
    case boolean(Bool)
    case null

    var foundationValue: Any {
        switch self {
        case .object(let values):
            values.mapValues(\.foundationValue)
        case .array(let values):
            values.map(\.foundationValue)
        case .string(let value):
            value
        case .integer(let value):
            NSNumber(value: value)
        case .unsigned(let value):
            NSNumber(value: value)
        case .floating(let value):
            NSNumber(value: value)
        case .boolean(let value):
            NSNumber(value: value)
        case .null:
            NSNull()
        }
    }

    static func fromFoundation(_ value: Any, depth: Int) throws -> DynamicJSONValue {
        guard depth <= 128 else {
            throw MorphError.invalidInput("The structured data exceeds the maximum nesting depth of 128.")
        }

        if value is NSNull { return .null }
        if let string = value as? String { return .string(string) }
        if let date = value as? Date { return .string(iso8601String(date)) }
        if let data = value as? Data { return .string(data.base64EncodedString()) }

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }

            let type = String(cString: number.objCType)
            if ["c", "s", "i", "l", "q"].contains(type) {
                return .integer(number.int64Value)
            }
            if ["C", "S", "I", "L", "Q"].contains(type) {
                let unsigned = number.uint64Value
                return unsigned <= UInt64(Int64.max) ? .integer(Int64(unsigned)) : .unsigned(unsigned)
            }
            return .floating(number.doubleValue)
        }

        if let array = value as? [Any] {
            guard array.count <= 100_000 else {
                throw MorphError.invalidInput("The structured data contains more than 100,000 array items.")
            }
            return .array(try array.map { try fromFoundation($0, depth: depth + 1) })
        }

        if let mapping = value as? [AnyHashable: Any] {
            guard mapping.count <= 10_000 else {
                throw MorphError.invalidInput("The structured data contains more than 10,000 keys in one table.")
            }
            var result: [String: DynamicJSONValue] = [:]
            for (key, item) in mapping {
                guard let stringKey = key.base as? String else {
                    throw MorphError.invalidInput("Structured-data conversions require string object keys.")
                }
                result[stringKey] = try fromFoundation(item, depth: depth + 1)
            }
            return .object(result)
        }

        throw MorphError.invalidInput("The input contains a YAML value that JSON, CSV, XML and TOML cannot represent.")
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
                return
            }
            if let value = try? container.decode(Int64.self) {
                self = .integer(value)
                return
            }
            if let value = try? container.decode(UInt64.self) {
                self = .unsigned(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .floating(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            if decoder.userInfo[dynamicJSONTOMLDateDecodingKey] as? Bool == true {
                if let value = try? container.decode(LocalDateTime.self) {
                    self = .string(localDateTimeString(value))
                    return
                }
                if let value = try? container.decode(LocalDate.self) {
                    self = .string(localDateString(value))
                    return
                }
                if let value = try? container.decode(LocalTime.self) {
                    self = .string(localTimeString(value))
                    return
                }
                if let value = try? container.decode(Date.self) {
                    self = .string(iso8601String(value))
                    return
                }
            }
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [DynamicJSONValue] = []
            while !container.isAtEnd {
                guard values.count < 100_000 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "The structured data contains more than 100,000 array items."))
                }
                values.append(try container.decode(DynamicJSONValue.self))
            }
            self = .array(values)
            return
        }

        if let container = try? decoder.container(keyedBy: DynamicJSONKey.self) {
            guard container.allKeys.count <= 10_000 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "The structured data contains more than 10,000 keys in one table."))
            }
            var values: [String: DynamicJSONValue] = [:]
            for key in container.allKeys {
                values[key.stringValue] = try container.decode(DynamicJSONValue.self, forKey: key)
            }
            self = .object(values)
            return
        }

        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "The value is not a supported structured-data type."))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let values):
            var container = encoder.container(keyedBy: DynamicJSONKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicJSONKey(stringValue: key))
            }
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .unsigned(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .floating(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .boolean(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private struct DynamicJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func localDateString(_ date: LocalDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
}

private func localDateTimeString(_ date: LocalDateTime) -> String {
    localDateString(LocalDate(year: date.year, month: date.month, day: date.day))
        + "T" + localTimeString(LocalTime(hour: date.hour, minute: date.minute, second: date.second, nanosecond: date.nanosecond))
}

private func localTimeString(_ time: LocalTime) -> String {
    let base = String(format: "%02d:%02d:%02d", time.hour, time.minute, time.second)
    guard time.nanosecond > 0 else { return base }
    let fraction = String(format: "%09d", time.nanosecond).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    return base + "." + fraction
}
