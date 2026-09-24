/// Quotes arguments for display and copying, so a copied command pastes as one safe line.
/// Jevcast never runs these strings itself.
public enum ShellQuote {
    public static func quote(_ argument: String) -> String {
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }
        if safe && !argument.isEmpty { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func join(_ arguments: [String]) -> String { arguments.map(quote).joined(separator: " ") }
}
