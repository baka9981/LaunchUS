import Foundation

/// Arithmetic typed into the search field, e.g. `12*(3+4)`.
enum Calculator {
    struct Result: Equatable {
        /// What the query was read as, e.g. "12*(3+4) =".
        let expression: String
        /// The answer for display, grouped.
        let display: String
        /// The answer to copy: plain digits, no grouping.
        let copyText: String
    }

    static func evaluate(_ query: String) -> Result? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 200, text.contains(where: \.isNumber) else { return nil }
        return arithmetic(text)
    }

    // MARK: - Arithmetic

    static func arithmetic(_ text: String) -> Result? {
        var expr = text.hasSuffix("=") ? String(text.dropLast()) : text
        expr = expr.trimmingCharacters(in: .whitespaces)
        var parser = Parser(expr)
        // A lone number (an app called "2048") isn't a sum.
        guard let value = parser.parse(), parser.sawOperator, value.isFinite else { return nil }
        return Result(expression: expr + " =", display: format(value, grouped: true), copyText: format(value, grouped: false))
    }

    /// Recursive descent: + - over × ÷ % over ^ over unary minus, with brackets.
    private struct Parser {
        let chars: [Character]
        var index = 0
        private(set) var sawOperator = false

        init(_ text: String) {
            chars = Array(text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
                .filter { !$0.isWhitespace })
        }

        mutating func parse() -> Double? {
            guard !chars.isEmpty, let value = expression(), index == chars.count else { return nil }
            return value
        }

        private var peek: Character? { index < chars.count ? chars[index] : nil }

        private mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let c = peek, c == "+" || c == "-" || c == "−" {
                index += 1; sawOperator = true
                guard let rhs = term() else { return nil }
                value = c == "+" ? value + rhs : value - rhs
            }
            return value
        }

        private mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let c = peek, "*×x/÷%".contains(c) {
                index += 1; sawOperator = true
                guard let rhs = power() else { return nil }
                switch c {
                case "/", "÷": value /= rhs
                case "%": value = value.truncatingRemainder(dividingBy: rhs)
                default: value *= rhs
                }
            }
            return value
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek == "^" {
                index += 1; sawOperator = true
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek == "-" || peek == "−" {
                index += 1
                return primary().map { -$0 }
            }
            if peek == "+" { index += 1 }
            return primary()
        }

        private mutating func primary() -> Double? {
            if peek == "(" || peek == "（" {
                index += 1
                guard let value = expression(), peek == ")" || peek == "）" else { return nil }
                index += 1
                return value
            }
            let start = index
            while let c = peek, c.isASCII, c.isNumber || c == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }

    // MARK: - Formatting

    static func format(_ value: Double, grouped: Bool) -> String {
        if value == 0 { return "0" }
        if abs(value) >= 1e15 || abs(value) < 1e-9 {
            return value.formatted(.number.notation(.scientific).precision(.significantDigits(1...10)).locale(Locale(identifier: "en_US_POSIX")))
        }
        let style = FloatingPointFormatStyle<Double>.number
            .precision(.significantDigits(1...12))
            .grouping(grouped ? .automatic : .never)
            .locale(Locale(identifier: "en_US"))
        return value.formatted(style)
    }
}
