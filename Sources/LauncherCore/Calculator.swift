import Foundation

/// A deliberately small arithmetic evaluator for launcher queries.
///
/// The parser accepts numbers, parentheses, the five arithmetic operators,
/// postfix percent, implicit multiplication before a parenthesis, and unit
/// conversions such as `10 km in mi`. It does not evaluate names, functions,
/// or code. A bare number is not a calculation, so it returns nil.
public enum Calculator {
    public static func evaluate(_ expression: String) -> String? {
        evaluate(expression, locale: .current)
    }

    public static func evaluate(_ expression: String, locale: Locale) -> String? {
        let normalized = expression
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")

        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.count <= maximumInputLength else {
            return nil
        }

        let separators = Separators(locale: locale)
        if let conversion = UnitConversion.evaluate(normalized, separators: separators) {
            return conversion
        }
        var parser = Parser(normalized, separators: separators)
        guard let result = parser.parse(), parser.sawOperation else { return nil }
        return format(result, separators: separators)
    }

    private static let maximumInputLength = 4_096
    private static let maximumMagnitude = 1.0e100
    private static let exactIntegerLimit = 9_007_199_254_740_992.0 // 2^53

    static func bounded(_ value: Double) -> Double? {
        guard value.isFinite, abs(value) <= maximumMagnitude else { return nil }
        return value
    }

    // Plain digits with no grouping keep the copied value pasteable.
    static func format(_ value: Double, separators: Separators) -> String {
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < exactIntegerLimit {
            return String(Int64(value))
        }
        let text = String(format: "%.15g", value)
        return separators.localize(text)
    }

    struct Separators {
        let decimal: Character
        let grouping: Character

        init(locale: Locale) {
            decimal = locale.decimalSeparator == "," ? "," : "."
            grouping = decimal == "," ? "." : ","
        }

        func localize(_ text: String) -> String {
            decimal == "." ? text : text.replacingOccurrences(of: ".", with: String(decimal))
        }

        /// Reads a literal of digits and separators. The locale's grouping
        /// character is accepted only in valid groups of three digits.
        /// Comma locales also accept a lone "." as a decimal point.
        func number(_ literal: String) -> Double? {
            let parts = literal.split(separator: decimal, omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            var integer = String(parts[0])
            var fraction = parts.count == 2 ? String(parts[1]) : nil
            guard fraction?.contains(grouping) != true else { return nil }
            if integer.contains(grouping) {
                let groups = integer.split(separator: grouping, omittingEmptySubsequences: false)
                if (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 }) {
                    integer = groups.joined()
                } else if decimal == ",", fraction == nil, groups.count == 2 {
                    integer = String(groups[0])
                    fraction = String(groups[1])
                } else {
                    return nil
                }
            }
            guard !integer.isEmpty || !(fraction ?? "").isEmpty else { return nil }
            return Double((integer.isEmpty ? "0" : integer) + (fraction.map { "." + $0 } ?? ""))
        }
    }

    struct Parser {
        private struct Term {
            let value: Double
            let percent: Bool
        }

        private let characters: [Character]
        private let separators: Separators
        private var index = 0
        private var operationCount = 0
        private var parenthesisDepth = 0
        /// True once the input has an operator, parenthesis, or percent.
        private(set) var sawOperation = false

        init(_ expression: String, separators: Separators) {
            characters = Array(expression)
            self.separators = separators
        }

        mutating func parse() -> Double? {
            guard let value = parseAdditive() else { return nil }
            skipWhitespace()
            guard index == characters.count else { return nil }
            return value
        }

        private mutating func parseAdditive() -> Double? {
            guard var value = parseMultiplicative()?.value else { return nil }

            while true {
                skipWhitespace()
                guard let operation = peek(), operation == "+" || operation == "-" else {
                    return value
                }

                index += 1
                sawOperation = true
                guard recordOperation(), let right = parseMultiplicative() else { return nil }
                // As in Spotlight, 100 + 10% adds ten percent of the left side.
                let operand = right.percent ? value * right.value : right.value
                let result = operation == "+" ? value + operand : value - operand
                guard let boundedResult = Calculator.bounded(result) else { return nil }
                value = boundedResult
            }
        }

        private mutating func parseMultiplicative() -> Term? {
            guard var term = parseUnary() else { return nil }

            while true {
                skipWhitespace()
                // A parenthesis directly after a factor is implicit multiplication.
                guard let operation = peek(), operation == "*" || operation == "/" || operation == "(" else {
                    return term
                }

                if operation != "(" { index += 1 }
                sawOperation = true
                guard recordOperation(), let right = parseUnary() else { return nil }
                if operation == "/" && right.value == 0 {
                    return nil
                }
                let result = operation == "/" ? term.value / right.value : term.value * right.value
                guard let boundedResult = Calculator.bounded(result) else { return nil }
                term = Term(value: boundedResult, percent: false)
            }
        }

        // Unary operators deliberately sit below exponentiation. This gives
        // the conventional result -2^2 == -4 while still allowing 2^-2.
        private mutating func parseUnary() -> Term? {
            skipWhitespace()
            guard let operation = peek(), operation == "+" || operation == "-" else {
                return parsePower()
            }

            index += 1
            guard recordOperation(), let term = parseUnary() else { return nil }
            let result = operation == "-" ? -term.value : term.value
            return Calculator.bounded(result).map { Term(value: $0, percent: term.percent) }
        }

        private mutating func parsePower() -> Term? {
            guard let base = parsePostfix() else { return nil }
            skipWhitespace()
            guard consume("^") else { return base }
            sawOperation = true
            guard recordOperation(), let exponent = parseUnary() else { return nil }
            return Calculator.bounded(pow(base.value, exponent.value)).map { Term(value: $0, percent: false) }
        }

        private mutating func parsePostfix() -> Term? {
            guard var value = parsePrimary() else { return nil }
            var percent = false

            while consume("%") {
                sawOperation = true
                percent = true
                guard recordOperation(), let result = Calculator.bounded(value / 100) else {
                    return nil
                }
                value = result
            }
            return Term(value: value, percent: percent)
        }

        private mutating func parsePrimary() -> Double? {
            skipWhitespace()
            if consume("(") {
                sawOperation = true
                parenthesisDepth += 1
                guard parenthesisDepth <= 64 else { return nil }
                defer { parenthesisDepth -= 1 }

                guard let value = parseAdditive(), consume(")") else { return nil }
                return value
            }

            return parseNumber()
        }

        private mutating func parseNumber() -> Double? {
            skipWhitespace()
            let start = index
            var sawDigit = false

            while let character = peek(), character.isNumber || character == "." || character == "," {
                sawDigit = sawDigit || character.isNumber
                index += 1
            }

            guard sawDigit else { return nil }
            guard let value = separators.number(String(characters[start..<index])) else { return nil }
            return Calculator.bounded(value)
        }

        private mutating func recordOperation() -> Bool {
            operationCount += 1
            return operationCount <= 1_024
        }

        private mutating func consume(_ expected: Character) -> Bool {
            skipWhitespace()
            guard peek() == expected else { return false }
            index += 1
            return true
        }

        private mutating func skipWhitespace() {
            while let character = peek(), character.isWhitespace {
                index += 1
            }
        }

        private func peek() -> Character? {
            guard index < characters.count else { return nil }
            return characters[index]
        }
    }
}
