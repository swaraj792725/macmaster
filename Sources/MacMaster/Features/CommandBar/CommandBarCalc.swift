import Foundation

/// Small safe math parser for the Command Bar. Pure Swift (no AppKit) so it can be tested standalone.
/// Supports + - * / ^ % ( ) , decimals, constants (pi, e) and common functions. Never traps: any bad input returns nil.
enum CommandBarCalc {
    struct Output: Equatable {
        let value: Double
        /// Plain number, safe to paste anywhere ("1024", "0.3333333333").
        let plain: String
        /// Same number with thousands separators for display.
        let pretty: String
        /// True for bare constants like "pi": worth showing, but not above real matches.
        let trivial: Bool
    }

    private static let maxLength = 160
    private static let maxDepth = 40

    /// Returns a result only for things that look like maths: at least one operator, function or constant,
    /// so plain numbers and ordinary words are left to the other providers.
    static func evaluate(_ raw: String) -> Output? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= maxLength else { return nil }
        guard let tokens = tokenize(input), !tokens.isEmpty else { return nil }
        guard tokens.contains(where: { $0.isMathy }) else { return nil }
        var p = Parser(tokens: tokens)
        guard let v = p.parseAll(), v.isFinite else { return nil }
        let hasOp = tokens.contains { if case .op = $0 { return true }; return false }
        let hasFn = tokens.contains { if case .ident(let n) = $0 { return !["pi", "π", "e", "tau"].contains(n) }; return false }
        return Output(value: v, plain: format(v, grouped: false), pretty: format(v, grouped: true), trivial: !hasOp && !hasFn)
    }

    // MARK: Formatting

    static func format(_ v: Double, grouped: Bool) -> String {
        if v == 0 { return "0" }
        let abs = Swift.abs(v)
        if abs >= 1e15 || abs < 1e-9 {
            return String(format: "%.10g", v)
        }
        // Up to 10 decimals, but trim float noise (0.1+0.2 -> 0.3).
        let rounded = (v * 1e10).rounded() / 1e10
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouped
        f.groupingSeparator = ","
        f.maximumFractionDigits = 10
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: rounded)) ?? String(format: "%.10g", v)
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(Double)
        case ident(String)
        case op(Character)      // + - * / ^ %
        case lparen, rparen, comma

        var isMathy: Bool {
            switch self {
            case .op, .ident: return true
            case .lparen, .rparen: return true
            case .number, .comma: return false
            }
        }
    }

    static func tokenize(_ s: String) -> [Token]? {
        var out: [Token] = []
        let chars = Array(s.lowercased().unicodeScalars)
        var i = 0
        func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }
        func isAlpha(_ c: Unicode.Scalar) -> Bool { (c.value >= 97 && c.value <= 122) || c == "π" }
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\u{00A0}" { i += 1; continue }
            if isDigit(c) || c == "." {
                var j = i
                var seenDot = false
                while j < chars.count, isDigit(chars[j]) || chars[j] == "." {
                    if chars[j] == "." { if seenDot { return nil }; seenDot = true }
                    j += 1
                }
                // exponent such as 1e5 / 2.5e-3 (only when digits follow)
                if j < chars.count, chars[j] == "e", j + 1 < chars.count {
                    var k = j + 1
                    if chars[k] == "-" || chars[k] == "+" { k += 1 }
                    if k < chars.count, isDigit(chars[k]) {
                        while k < chars.count, isDigit(chars[k]) { k += 1 }
                        j = k
                    }
                }
                let text = String(String.UnicodeScalarView(chars[i..<j]))
                guard text != ".", let v = Double(text), v.isFinite else { return nil }
                out.append(.number(v))
                i = j
                continue
            }
            if isAlpha(c) {
                var j = i
                while j < chars.count, isAlpha(chars[j]) { j += 1 }
                out.append(.ident(String(String.UnicodeScalarView(chars[i..<j]))))
                i = j
                continue
            }
            switch c {
            case "+": out.append(.op("+"))
            case "-", "−", "–": out.append(.op("-"))
            case "*", "×", "·": out.append(.op("*"))
            case "/", "÷": out.append(.op("/"))
            case "^": out.append(.op("^"))
            case "%": out.append(.op("%"))
            case "(": out.append(.lparen)
            case ")": out.append(.rparen)
            case ",": out.append(.comma)
            default: return nil
            }
            // "**" means power
            if c == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" { out[out.count - 1] = .op("^"); i += 1 }
                else { out[out.count - 1] = .op("*") }
            }
            i += 1
            if out.count > 200 { return nil }
        }
        return out
    }

    // MARK: Parser

    private struct Parser {
        let tokens: [Token]
        var pos = 0
        var depth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        mutating func parseAll() -> Double? {
            guard let v = expr() else { return nil }
            return pos == tokens.count ? v : nil
        }

        var peek: Token? { pos < tokens.count ? tokens[pos] : nil }

        // expr := term (('+'|'-') term)*
        mutating func expr() -> Double? {
            depth += 1; defer { depth -= 1 }
            guard depth < CommandBarCalc.maxDepth, var v = term() else { return nil }
            while case .op(let o)? = peek, o == "+" || o == "-" {
                pos += 1
                guard let r = term() else { return nil }
                v = o == "+" ? v + r : v - r
            }
            return v
        }

        // term := unary (('*'|'/'|'%') unary | implicit-multiply unary)*
        mutating func term() -> Double? {
            guard var v = unary() else { return nil }
            while true {
                if case .op(let o)? = peek, o == "*" || o == "/" || o == "%" {
                    // A trailing % (nothing operand-like after it) is "percent", handled in postfix.
                    pos += 1
                    guard let r = unary() else { return nil }
                    switch o {
                    case "*": v *= r
                    case "/": guard r != 0 else { return nil }; v /= r
                    default: guard r != 0 else { return nil }; v = fmod(v, r)
                    }
                } else if startsOperand(peek) {
                    guard let r = unary() else { return nil }   // implicit multiplication: 2pi, 3(4+1)
                    v *= r
                } else {
                    break
                }
                if !v.isFinite { return nil }
            }
            return v
        }

        func startsOperand(_ t: Token?) -> Bool {
            switch t {
            case .number?, .ident?, .lparen?: return true
            default: return false
            }
        }

        // unary := ('-'|'+') unary | power
        mutating func unary() -> Double? {
            depth += 1; defer { depth -= 1 }
            guard depth < CommandBarCalc.maxDepth else { return nil }
            if case .op(let o)? = peek, o == "-" || o == "+" {
                pos += 1
                guard let v = unary() else { return nil }
                return o == "-" ? -v : v
            }
            return power()
        }

        // power := postfix ('^' unary)?   (right associative, binds tighter than unary minus on the left: -2^2 = -4)
        mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            if case .op("^")? = peek {
                pos += 1
                guard let e = unary() else { return nil }
                let r = pow(base, e)
                return r.isFinite ? r : nil
            }
            return base
        }

        // postfix := primary '%'?   ("50%" = 0.5; "%" followed by an operand is modulo, handled in term())
        mutating func postfix() -> Double? {
            guard let v = primary() else { return nil }
            if case .op("%")? = peek {
                let next = pos + 1 < tokens.count ? tokens[pos + 1] : nil
                if !startsOperand(next) && !isUnarySign(next) { pos += 1; return v / 100 }
            }
            return v
        }

        func isUnarySign(_ t: Token?) -> Bool {
            if case .op(let o)? = t { return o == "-" || o == "+" }
            return false
        }

        mutating func primary() -> Double? {
            guard let t = peek else { return nil }
            switch t {
            case .number(let v):
                pos += 1
                return v
            case .lparen:
                pos += 1
                guard let v = expr() else { return nil }
                guard case .rparen? = peek else { return nil }
                pos += 1
                return v
            case .ident(let name):
                pos += 1
                switch name {
                case "pi", "π": return Double.pi
                case "e": return M_E
                case "tau": return 2 * Double.pi
                default: break
                }
                guard case .lparen? = peek else { return nil }
                pos += 1
                var args: [Double] = []
                if case .rparen? = peek { pos += 1 } else {
                    while true {
                        guard let a = expr() else { return nil }
                        args.append(a)
                        if case .comma? = peek { pos += 1; if args.count > 3 { return nil }; continue }
                        guard case .rparen? = peek else { return nil }
                        pos += 1
                        break
                    }
                }
                return CommandBarCalc.apply(name, args)
            default:
                return nil
            }
        }
    }

    static func apply(_ name: String, _ a: [Double]) -> Double? {
        func one(_ f: (Double) -> Double) -> Double? {
            guard a.count == 1 else { return nil }
            let r = f(a[0])
            return r.isFinite ? r : nil
        }
        switch name {
        case "sqrt": return one { $0 >= 0 ? $0.squareRoot() : .nan }
        case "cbrt": return one { cbrt($0) }
        case "sin": return one { sin($0) }
        case "cos": return one { cos($0) }
        case "tan": return one { tan($0) }
        case "asin": return one { $0 >= -1 && $0 <= 1 ? asin($0) : .nan }
        case "acos": return one { $0 >= -1 && $0 <= 1 ? acos($0) : .nan }
        case "atan": return one { atan($0) }
        case "log", "log10": return one { $0 > 0 ? log10($0) : .nan }
        case "log2": return one { $0 > 0 ? log2($0) : .nan }
        case "ln": return one { $0 > 0 ? log($0) : .nan }
        case "exp": return one { exp($0) }
        case "abs": return one { Swift.abs($0) }
        case "round": return one { $0.rounded() }
        case "floor": return one { $0.rounded(.down) }
        case "ceil": return one { $0.rounded(.up) }
        case "deg": return one { $0 * 180 / .pi }
        case "rad": return one { $0 * .pi / 180 }
        case "pow": guard a.count == 2 else { return nil }; let r = pow(a[0], a[1]); return r.isFinite ? r : nil
        case "min": guard a.count >= 1, let m = a.min() else { return nil }; return m
        case "max": guard a.count >= 1, let m = a.max() else { return nil }; return m
        default: return nil
        }
    }
}
