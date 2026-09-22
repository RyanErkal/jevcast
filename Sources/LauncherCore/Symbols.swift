import Foundation

/// A bundled list of emoji and typographic symbols, searched on this Mac only.
public enum Symbols {
    public struct Entry: Equatable, Sendable {
        public let character: String
        public let name: String
        public let keywords: [String]
    }

    /// Reads ":tada", "emoji party", "symbol arrow", or "emoji" alone. Returns the search text.
    public static func query(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":"), trimmed.count >= 2, !trimmed.dropFirst().contains(" "), !trimmed.dropFirst().allSatisfy(\.isNumber) {
            return String(trimmed.dropFirst())
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first?.lowercased(), ["emoji", "emojis", "symbol", "symbols", "character", "char"].contains(first) else { return nil }
        return parts.count > 1 ? parts[1] : ""
    }

    public static func search(_ text: String, limit: Int = 30) -> [Entry] {
        let needle = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Array(all.prefix(limit)) }
        let words = needle.split(separator: " ").map(String.init)
        let scored = all.compactMap { entry -> (Entry, Int)? in
            let haystack = ([entry.name] + entry.keywords).map { $0.lowercased() }
            guard words.allSatisfy({ word in haystack.contains { $0.contains(word) } }) else { return nil }
            let exact = haystack.contains(needle) ? 0 : haystack.contains { $0.hasPrefix(needle) } ? 1 : 2
            return (entry, exact)
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    private static func e(_ character: String, _ name: String, _ keywords: String = "") -> Entry {
        Entry(character: character, name: name, keywords: keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    public static let all: [Entry] = [
        // Symbols
        e("⌘", "command", "cmd,key,mac"), e("⌥", "option", "alt,key,mac"), e("⇧", "shift", "key"), e("⌃", "control", "ctrl,key"),
        e("⎋", "escape", "esc,key"), e("↩", "return", "enter,key"), e("⌫", "delete", "backspace,key"), e("⇥", "tab", "key"),
        e("→", "right arrow", "arrow"), e("←", "left arrow", "arrow"), e("↑", "up arrow", "arrow"), e("↓", "down arrow", "arrow"),
        e("↔", "left right arrow", "arrow"), e("⇒", "double right arrow", "implies,arrow"), e("↗", "north east arrow", "arrow"),
        e("✓", "check mark", "tick,done,yes"), e("✗", "cross mark", "no,x"), e("•", "bullet", "dot"), e("·", "middle dot", "interpunct,dot"),
        e("…", "ellipsis", "dots"), e("—", "em dash", "dash"), e("–", "en dash", "dash"), e("°", "degree", "temperature"),
        e("±", "plus minus", "math"), e("×", "multiply", "times,math"), e("÷", "divide", "math"), e("≈", "approximately", "almost equal,math"),
        e("≠", "not equal", "math"), e("≤", "less than or equal", "math"), e("≥", "greater than or equal", "math"), e("∞", "infinity", "math"),
        e("√", "square root", "math"), e("π", "pi", "math"), e("∑", "sum", "sigma,math"), e("Δ", "delta", "change,math"),
        e("€", "euro", "currency,money"), e("£", "pound", "currency,money,gbp"), e("¥", "yen", "currency,money"), e("¢", "cent", "currency"),
        e("©", "copyright", "legal"), e("®", "registered", "legal"), e("™", "trademark", "legal"), e("§", "section", "legal"),
        e("¶", "pilcrow", "paragraph"), e("†", "dagger", "footnote"), e("‰", "per mille", "percent"), e("½", "one half", "fraction"),
        e("¼", "one quarter", "fraction"), e("¾", "three quarters", "fraction"), e("“", "left double quote", "quote"), e("”", "right double quote", "quote"),
        e("‘", "left single quote", "quote"), e("’", "apostrophe", "right single quote"), e("«", "left guillemet", "quote"), e("»", "right guillemet", "quote"),
        e("★", "black star", "star,favourite"), e("☆", "white star", "star"), e("♥", "heart suit", "love"), e("☀", "sun symbol", "weather"),
        e("☂", "umbrella symbol", "rain"), e("⚠", "warning sign", "alert"), e("♪", "music note", "song"), e("✉", "envelope", "mail,email"),
        e("☎", "telephone", "phone"), e("⌚", "watch", "time"), e("⏎", "return symbol", "enter"), e("␣", "space symbol", "blank"),
        // Emoji
        e("😀", "grinning face", "smile,happy"), e("😂", "tears of joy", "laugh,lol,funny"), e("🙂", "slightly smiling", "smile"),
        e("😉", "wink", "flirt"), e("😍", "heart eyes", "love"), e("🥰", "smiling hearts", "love,adore"), e("😎", "sunglasses", "cool"),
        e("🤔", "thinking", "hmm,think"), e("🙃", "upside down", "silly"), e("😅", "sweat smile", "phew,nervous"), e("😭", "crying", "sad,sob"),
        e("😢", "tear", "sad"), e("😡", "angry", "mad,rage"), e("😱", "scream", "shock,omg"), e("🤯", "mind blown", "wow,exploding"),
        e("😴", "sleeping", "tired,zzz"), e("🥳", "partying face", "party,celebrate,birthday"), e("🤝", "handshake", "deal,agree"),
        e("👍", "thumbs up", "like,yes,ok,good"), e("👎", "thumbs down", "dislike,no,bad"), e("👏", "clap", "applause,well done"),
        e("🙌", "raised hands", "hooray,celebrate"), e("🙏", "folded hands", "please,thanks,pray"), e("👋", "wave", "hello,bye,hi"),
        e("💪", "flexed biceps", "strong,muscle"), e("👀", "eyes", "look,see"), e("🫡", "salute", "respect,yes sir"), e("🤷", "shrug", "dunno,whatever"),
        e("🤦", "facepalm", "doh"), e("❤️", "red heart", "love,heart"), e("💔", "broken heart", "sad"), e("🔥", "fire", "lit,hot,flame"),
        e("✨", "sparkles", "magic,shiny,new"), e("⭐", "star", "favourite"), e("🌟", "glowing star", "shine"), e("💯", "hundred points", "perfect,100"),
        e("🎉", "tada", "party,celebrate,congrats,popper"), e("🎊", "confetti ball", "party"), e("🎁", "gift", "present,birthday"),
        e("🎂", "birthday cake", "cake,birthday"), e("🍾", "champagne", "celebrate,bottle"), e("🥂", "clinking glasses", "cheers,toast"),
        e("☕", "coffee", "hot drink,tea"), e("🍵", "tea", "green tea,cup"), e("🍺", "beer", "drink,pint"), e("🍕", "pizza", "food"),
        e("🍔", "burger", "food,hamburger"), e("🍎", "red apple", "fruit"), e("🌮", "taco", "food"), e("🍣", "sushi", "food"),
        e("✅", "check mark button", "done,yes,tick,complete"), e("❌", "cross mark", "no,wrong,fail"), e("⚠️", "warning", "alert,caution"),
        e("❓", "question mark", "what,question"), e("❗", "exclamation mark", "important"), e("💡", "light bulb", "idea"),
        e("📌", "pushpin", "pin"), e("📎", "paperclip", "attach"), e("📝", "memo", "note,write"), e("📅", "calendar", "date,schedule"),
        e("⏰", "alarm clock", "time,timer,wake"), e("⏳", "hourglass", "wait,time"), e("🔒", "locked", "lock,secure,private"),
        e("🔑", "key", "password,unlock"), e("🔗", "link", "chain,url"), e("📦", "package", "box,ship,deploy"), e("🚀", "rocket", "launch,ship,fast"),
        e("🐛", "bug", "insect,error"), e("🛠️", "hammer and wrench", "tools,fix,build"), e("⚙️", "gear", "settings,cog"),
        e("💻", "laptop", "computer,mac"), e("🖥️", "desktop computer", "monitor,screen"), e("⌨️", "keyboard", "type"),
        e("📱", "mobile phone", "iphone,phone"), e("📷", "camera", "photo"), e("🎵", "musical note", "music,song"), e("🎧", "headphones", "music,listen"),
        e("📈", "chart increasing", "growth,up,stonks"), e("📉", "chart decreasing", "down,loss"), e("💰", "money bag", "cash,rich"),
        e("💸", "money with wings", "spend,pay"), e("🏆", "trophy", "win,award"), e("🎯", "direct hit", "target,goal,bullseye"),
        e("🧠", "brain", "smart,think"), e("🤖", "robot", "bot,ai"), e("👻", "ghost", "boo,halloween"), e("💀", "skull", "dead,lol"),
        e("🐶", "dog face", "puppy,pet"), e("🐱", "cat face", "kitten,pet"), e("🦄", "unicorn", "magic"), e("🌈", "rainbow", "pride"),
        e("☀️", "sun", "sunny,weather"), e("🌧️", "rain cloud", "rain,weather"), e("❄️", "snowflake", "snow,cold"), e("🌙", "crescent moon", "night"),
        e("🌍", "globe", "world,earth"), e("🏠", "house", "home"), e("✈️", "airplane", "travel,flight"), e("🚗", "car", "drive"),
        e("⚡", "high voltage", "lightning,zap,fast"), e("💬", "speech balloon", "chat,message,comment"), e("👉", "point right", "this"),
        e("👇", "point down", "below"), e("🫶", "heart hands", "love,thanks")
    ]
}
