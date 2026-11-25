// Copyright (c) 2026 Bates LLC. All rights reserved.
//
// A reader for Lua *data* files (Vanaguide/data/*.lua): table constructors of strings, numbers,
// booleans, nil and nested tables. It evaluates nothing. Statements around the tables
// (`local A = {}`, `A.sets = { ... }`, `return A`) are skipped, and every top-level table
// constructor in the file is returned in order. An expression it cannot read as a literal
// (a variable, a function call) becomes `.other` rather than failing the whole file.

import Foundation

indirect enum LuaValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case table(LuaTable)
    case other

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? Int(d) : nil
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var table: LuaTable? { if case .table(let t) = self { return t } else { return nil } }
}

struct LuaTable: Equatable {
    /// Positional entries, in order.
    var array: [LuaValue] = []
    /// Keyed entries; numeric keys are stored as their decimal text (`[12] =` is "12").
    var hash: [String: LuaValue] = [:]
    /// Keyed entries in source order, for stable output.
    var keys: [String] = []

    subscript(_ k: String) -> LuaValue? { hash[k] }

    /// Every child value, keyed ones first in source order, then positional ones.
    var children: [(key: String?, value: LuaValue)] {
        keys.compactMap { k in hash[k].map { (Optional(k), $0) } } + array.map { (nil, $0) }
    }
}

struct LuaDataReader {
    private let s: [UInt8]
    private var i = 0

    init(_ text: String) { s = Array(text.utf8) }

    /// Every top-level table constructor in the file, in order.
    static func tables(in text: String) -> [LuaTable] {
        var r = LuaDataReader(text)
        var out: [LuaTable] = []
        while r.i < r.s.count {
            r.skipSpaceAndComments()
            guard r.i < r.s.count else { break }
            let c = r.s[r.i]
            if c == UInt8(ascii: "{") {
                if let t = r.parseTable() { out.append(t) } else { break }
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
                _ = r.parseQuoted()
            } else if c == UInt8(ascii: "["), r.longBracketLevel() != nil {
                _ = r.parseLongString()
            } else {
                r.i += 1
            }
        }
        return out
    }

    // MARK: lexing

    private func peek(_ o: Int = 0) -> UInt8? { i + o < s.count ? s[i + o] : nil }

    private mutating func skipSpaceAndComments() {
        while i < s.count {
            let c = s[i]
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            if c == UInt8(ascii: "-"), peek(1) == UInt8(ascii: "-") {
                i += 2
                if peek() == UInt8(ascii: "["), longBracketLevel() != nil {
                    _ = parseLongString()
                } else {
                    while i < s.count, s[i] != 10 { i += 1 }
                }
                continue
            }
            break
        }
    }

    /// At `[`: the level of a long bracket `[==[` opening here, or nil.
    private func longBracketLevel() -> Int? {
        guard peek() == UInt8(ascii: "[") else { return nil }
        var j = i + 1, level = 0
        while j < s.count, s[j] == UInt8(ascii: "=") { level += 1; j += 1 }
        return j < s.count && s[j] == UInt8(ascii: "[") ? level : nil
    }

    private mutating func parseLongString() -> String? {
        guard let level = longBracketLevel() else { return nil }
        i += level + 2
        if peek() == 13 { i += 1 }
        if peek() == 10 { i += 1 }
        let start = i
        while i < s.count {
            if s[i] == UInt8(ascii: "]") {
                var j = i + 1, n = 0
                while j < s.count, s[j] == UInt8(ascii: "=") { n += 1; j += 1 }
                if n == level, j < s.count, s[j] == UInt8(ascii: "]") {
                    let text = String(decoding: s[start..<i], as: UTF8.self)
                    i = j + 1
                    return text
                }
            }
            i += 1
        }
        return nil
    }

    private mutating func parseQuoted() -> String? {
        let q = s[i]
        i += 1
        var bytes: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if c == q { i += 1; return String(decoding: bytes, as: UTF8.self) }
            if c == 10 { return nil }
            if c == UInt8(ascii: "\\"), i + 1 < s.count {
                let e = s[i + 1]
                i += 2
                switch e {
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "t"): bytes.append(9)
                case UInt8(ascii: "r"): bytes.append(13)
                case UInt8(ascii: "a"): bytes.append(7)
                case UInt8(ascii: "b"): bytes.append(8)
                case UInt8(ascii: "f"): bytes.append(12)
                case UInt8(ascii: "v"): bytes.append(11)
                case 10: bytes.append(10)
                case UInt8(ascii: "z"):
                    while i < s.count, [32, 9, 10, 13].contains(s[i]) { i += 1 }
                case UInt8(ascii: "x"):
                    if i + 1 < s.count, let v = UInt8(String(decoding: s[i...(i + 1)], as: UTF8.self), radix: 16) {
                        bytes.append(v); i += 2
                    }
                case UInt8(ascii: "u"):
                    if peek() == UInt8(ascii: "{"), let close = s[i...].firstIndex(of: UInt8(ascii: "}")),
                       let v = UInt32(String(decoding: s[(i + 1)..<close], as: UTF8.self), radix: 16),
                       let sc = Unicode.Scalar(v) {
                        bytes.append(contentsOf: Array(String(Character(sc)).utf8)); i = close + 1
                    }
                case UInt8(ascii: "0")...UInt8(ascii: "9"):
                    var v = Int(e - 48), n = 1
                    while n < 3, let d = peek(), d >= 48, d <= 57 { v = v * 10 + Int(d - 48); i += 1; n += 1 }
                    bytes.append(UInt8(truncatingIfNeeded: v))
                default: bytes.append(e)
                }
                continue
            }
            bytes.append(c)
            i += 1
        }
        return nil
    }

    private static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
    }
    private static func isIdent(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }

    private mutating func parseName() -> String? {
        guard let c = peek(), Self.isIdentStart(c) else { return nil }
        let start = i
        while let c = peek(), Self.isIdent(c) { i += 1 }
        return String(decoding: s[start..<i], as: UTF8.self)
    }

    private mutating func parseNumber() -> Double? {
        let start = i
        var neg = false
        if peek() == UInt8(ascii: "-") { neg = true; i += 1; skipSpaceAndComments() }
        let body = i
        if peek() == UInt8(ascii: "0"), peek(1) == UInt8(ascii: "x") || peek(1) == UInt8(ascii: "X") {
            i += 2
            let h = i
            while let c = peek(), (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) { i += 1 }
            guard let v = UInt64(String(decoding: s[h..<i], as: UTF8.self), radix: 16) else { i = start; return nil }
            return neg ? -Double(v) : Double(v)
        }
        while let c = peek(), (c >= 48 && c <= 57) || c == UInt8(ascii: ".") || c == UInt8(ascii: "e")
            || c == UInt8(ascii: "E")
            || ((c == UInt8(ascii: "-") || c == UInt8(ascii: "+")) && (s[i - 1] == UInt8(ascii: "e") || s[i - 1] == UInt8(ascii: "E"))) {
            i += 1
        }
        guard i > body, let v = Double(String(decoding: s[body..<i], as: UTF8.self)) else { i = start; return nil }
        return neg ? -v : v
    }

    /// Skip an expression this reader does not evaluate, up to the next separator at its depth.
    private mutating func skipExpression() {
        var depth = 0
        while i < s.count {
            skipSpaceAndComments()
            guard let c = peek() else { return }
            if depth == 0, c == UInt8(ascii: ",") || c == UInt8(ascii: ";") || c == UInt8(ascii: "}")
                || c == UInt8(ascii: "]") || c == UInt8(ascii: ")") { return }
            if c == UInt8(ascii: "{") || c == UInt8(ascii: "(") || c == UInt8(ascii: "[") { depth += 1 }
            if c == UInt8(ascii: "}") || c == UInt8(ascii: ")") || c == UInt8(ascii: "]") { depth -= 1 }
            if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") { _ = parseQuoted(); continue }
            i += 1
        }
    }

    private mutating func parseValue() -> LuaValue? {
        skipSpaceAndComments()
        guard let c = peek() else { return nil }
        let v: LuaValue
        if c == UInt8(ascii: "{") {
            guard let t = parseTable() else { return nil }
            v = .table(t)
        } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
            guard let str = parseQuoted() else { return nil }
            v = .string(str)
        } else if c == UInt8(ascii: "["), longBracketLevel() != nil {
            guard let str = parseLongString() else { return nil }
            v = .string(str)
        } else if (c >= 48 && c <= 57) || c == UInt8(ascii: "-") || c == UInt8(ascii: ".") {
            guard let d = parseNumber() else { skipExpression(); return .other }
            v = .number(d)
        } else if Self.isIdentStart(c) {
            let save = i
            let name = parseName()
            switch name {
            case "true": v = .bool(true)
            case "false": v = .bool(false)
            case "nil": v = .null
            default: i = save; skipExpression(); return .other
            }
        } else {
            skipExpression()
            return .other
        }
        // A literal followed by an operator (`1 + 2`, `'a' .. 'b'`) is an expression: skip it.
        skipSpaceAndComments()
        if let n = peek(), n != UInt8(ascii: ","), n != UInt8(ascii: ";"), n != UInt8(ascii: "}"),
           n != UInt8(ascii: "]") {
            skipExpression()
            if case .table = v { return v }
            return .other
        }
        return v
    }

    /// At `{`: one table constructor.
    private mutating func parseTable() -> LuaTable? {
        guard peek() == UInt8(ascii: "{") else { return nil }
        i += 1
        var t = LuaTable()
        func set(_ k: String, _ v: LuaValue) {
            if t.hash[k] == nil { t.keys.append(k) }
            t.hash[k] = v
        }
        while true {
            skipSpaceAndComments()
            guard let c = peek() else { return nil }
            if c == UInt8(ascii: "}") { i += 1; return t }
            if c == UInt8(ascii: ",") || c == UInt8(ascii: ";") { i += 1; continue }
            if c == UInt8(ascii: "["), longBracketLevel() == nil {
                // [key] = value
                i += 1
                guard let k = parseValue() else { return nil }
                skipSpaceAndComments()
                guard peek() == UInt8(ascii: "]") else { return nil }
                i += 1
                skipSpaceAndComments()
                guard peek() == UInt8(ascii: "=") else { return nil }
                i += 1
                guard let v = parseValue() else { return nil }
                if let ks = k.string { set(ks, v) }
                continue
            }
            if let ch = peek(), Self.isIdentStart(ch) {
                let save = i
                if let name = parseName() {
                    skipSpaceAndComments()
                    if peek() == UInt8(ascii: "="), peek(1) != UInt8(ascii: "=") {
                        i += 1
                        guard let v = parseValue() else { return nil }
                        set(name, v)
                        continue
                    }
                }
                i = save
            }
            guard let v = parseValue() else { return nil }
            t.array.append(v)
        }
    }
}
