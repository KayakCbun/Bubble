import Foundation

enum RPCID: Hashable {
    case int(Int)
    case string(String)

    static func parse(_ value: Any?) -> RPCID? {
        if let int = value as? Int {
            return .int(int)
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return .int(number.intValue)
        }
        if let string = value as? String {
            return .string(string)
        }
        return nil
    }

    var jsonValue: Any {
        switch self {
        case .int(let int): int
        case .string(let string): string
        }
    }
}

struct RPCError: Error, LocalizedError {
    var code: Int
    var message: String
    var errorDescription: String? { message }
}

enum JSONValue {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    static func advertised(_ value: Any?) -> Bool {
        if let bool = bool(value) { return bool }
        if value is [String: Any] { return true }
        return false
    }

    static func nested(_ root: [String: Any], _ keys: String...) -> Any? {
        var current: Any = root
        for key in keys {
            guard let object = current as? [String: Any] else { return nil }
            guard let next = object[key] else { return nil }
            current = next
        }
        return current
    }
}

extension Dictionary where Key == String {
    func string(_ key: String) -> String? { self[key] as? String }
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
}
