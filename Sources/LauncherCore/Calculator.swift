import Foundation

/// A deliberately small arithmetic evaluator for launcher queries.
///
/// The parser accepts numbers, parentheses, the five arithmetic operators,
/// and postfix percent. It does not evaluate names, functions, or code.
public enum Calculator {
    public static func evaluate(_ expression: String) -> String? {
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

        var parser = Parser(normalized)
        guard let result = parser.parse() else { return nil }
        return format(result)
    }

    private static let maximumInputLength = 4_096
    private static let maximumMagnitude = 1.0e100

    private static func bounded(_ value: Double) -> Double? {
        guard value.isFinite, abs(value) <= maximumMagnitude else { return nil }
        return value
    }

    private static func format(_ value: Double) -> String {
        if value == 0 {
            return "0"
        }

        // A fixed locale and significant-digit count keep output stable across
        // machines while retaining useful precision for normal calculations.
        return String(
            format: "%.12g",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private var operationCount = 0
        private var parenthesisDepth = 0

        init(_ expression: String) {
            characters = Array(expression)
        }

        mutating func parse() -> Double? {
            guard let value = parseAdditive() else { return nil }
            skipWhitespace()
            guard index == characters.count else { return nil }
            return value
        }

        private mutating func parseAdditive() -> Double? {
            guard var value = parseMultiplicative() else { return nil }

            while true {
                skipWhitespace()
                guard let operation = peek(), operation == "+" || operation == "-" else {
                    return value
                }

                index += 1
                guard recordOperation(), let right = parseMultiplicative() else { return nil }
                let result = operation == "+" ? value + right : value - right
                guard let boundedResult = Calculator.bounded(result) else { return nil }
                value = boundedResult
            }
        }

        private mutating func parseMultiplicative() -> Double? {
            guard var value = parseUnary() else { return nil }

            while true {
                skipWhitespace()
                guard let operation = peek(), operation == "*" || operation == "/" else {
                    return value
                }

                index += 1
                guard recordOperation(), let right = parseUnary() else { return nil }
                if operation == "/" && right == 0 {
                    return nil
                }
                let result = operation == "*" ? value * right : value / right
                guard let boundedResult = Calculator.bounded(result) else { return nil }
                value = boundedResult
            }
        }

        // Unary operators deliberately sit below exponentiation. This gives
        // the conventional result -2^2 == -4 while still allowing 2^-2.
        private mutating func parseUnary() -> Double? {
            skipWhitespace()
            guard let operation = peek(), operation == "+" || operation == "-" else {
                return parsePower()
            }

            index += 1
            guard recordOperation(), let value = parseUnary() else { return nil }
            let result = operation == "-" ? -value : value
            return Calculator.bounded(result)
        }

        private mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            skipWhitespace()
            guard consume("^") else { return base }
            guard recordOperation(), let exponent = parseUnary() else { return nil }
            return Calculator.bounded(pow(base, exponent))
        }

        private mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }

            while consume("%") {
                guard recordOperation(), let result = Calculator.bounded(value / 100) else {
                    return nil
                }
                value = result
            }
            return value
        }

        private mutating func parsePrimary() -> Double? {
            skipWhitespace()
            if consume("(") {
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
            var sawDecimal = false

            while let character = peek() {
                if character.isNumber {
                    sawDigit = true
                    index += 1
                } else if character == "." && !sawDecimal {
                    sawDecimal = true
                    index += 1
                } else {
                    break
                }
            }

            guard sawDigit else { return nil }
            let literal = String(characters[start..<index])
            guard let value = Double(literal) else { return nil }
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
