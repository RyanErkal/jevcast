/// The one inline message the launcher shows above its footer.
struct Notice: Equatable {
    enum Tone { case warning, info }
    enum Action: Equatable {
        case allowAccessibility
        var title: String {
            switch self { case .allowAccessibility: return "Allow" }
        }
    }
    let symbol: String
    let text: String
    let tone: Tone
    var action: Action? = nil
}
