import Foundation

/// A place a time can be in: a city, region, country, or zone abbreviation, and its IANA zone.
public struct TimeZonePlace: Equatable, Sendable {
    public let name: String
    public let zone: String
    /// Set when the name covers several zones and one was assumed, such as "US Eastern".
    public let note: String?

    public var timeZone: TimeZone? { TimeZone(identifier: zone) }
}

/// A fixed, bundled table. Nothing is looked up on the network.
public enum TimeZonePlaces {
    /// One row per place: zone, display name, the names people type, and a note when a zone was assumed.
    private static let table: [(zone: String, name: String, aliases: [String], note: String?)] = [
        ("America/Los_Angeles", "Pacific Time", ["pst", "pdt", "pt", "pacific", "pacific time", "west coast"], nil),
        ("America/Los_Angeles", "California", ["california", "ca", "cali", "los angeles", "la", "san francisco", "sf", "san diego", "san jose", "silicon valley", "seattle", "washington state", "portland", "oregon", "las vegas", "vegas", "nevada", "vancouver"], nil),
        ("America/Denver", "Mountain Time", ["mst", "mdt", "mt", "mountain", "mountain time", "denver", "colorado", "utah", "salt lake city", "calgary"], nil),
        ("America/Phoenix", "Arizona", ["arizona", "phoenix"], nil),
        ("America/Chicago", "Central Time", ["cst", "cdt", "ct", "central", "central time", "chicago", "texas", "dallas", "houston", "austin", "san antonio", "illinois", "minneapolis", "minnesota", "new orleans", "nashville", "tennessee", "kansas city", "missouri", "winnipeg", "mexico city"], nil),
        ("America/New_York", "Eastern Time", ["est", "edt", "et", "eastern", "eastern time", "east coast"], nil),
        ("America/New_York", "New York", ["new york", "nyc", "ny", "manhattan", "brooklyn", "atlanta", "georgia", "boston", "massachusetts", "miami", "florida", "orlando", "washington dc", "dc", "philadelphia", "pennsylvania", "new jersey", "nj", "detroit", "michigan", "ohio", "charlotte", "north carolina", "virginia", "toronto", "montreal", "ottawa"], nil),
        ("America/New_York", "United States", ["us", "usa", "united states", "america"], "US Eastern assumed"),
        ("America/Toronto", "Canada", ["canada"], "Canada Eastern assumed"),
        ("America/Anchorage", "Alaska", ["alaska", "anchorage", "akst", "akdt"], nil),
        ("Pacific/Honolulu", "Hawaii", ["hawaii", "honolulu", "hst"], nil),
        ("America/Halifax", "Atlantic Time", ["halifax", "nova scotia", "ast", "adt"], nil),
        ("America/Sao_Paulo", "Brazil", ["brazil", "sao paulo", "rio", "rio de janeiro"], "Brasília time assumed"),
        ("America/Argentina/Buenos_Aires", "Argentina", ["argentina", "buenos aires"], nil),
        ("America/Bogota", "Colombia", ["colombia", "bogota"], nil),
        ("America/Lima", "Peru", ["peru", "lima"], nil),
        ("America/Santiago", "Chile", ["chile", "santiago"], nil),
        ("Europe/London", "UK", ["uk", "u.k.", "united kingdom", "britain", "great britain", "england", "scotland", "wales", "northern ireland", "london", "manchester", "birmingham", "leeds", "liverpool", "glasgow", "edinburgh", "cardiff", "belfast", "bristol", "gmt", "bst", "british time"], nil),
        ("Europe/Dublin", "Ireland", ["ireland", "dublin", "cork", "galway", "irish time"], nil),
        ("Europe/Lisbon", "Portugal", ["portugal", "lisbon", "porto"], nil),
        ("Europe/Paris", "France", ["france", "paris", "lyon", "marseille", "nice"], nil),
        ("Europe/Madrid", "Spain", ["spain", "madrid", "barcelona", "valencia", "seville"], nil),
        ("Europe/Berlin", "Germany", ["germany", "berlin", "munich", "hamburg", "frankfurt", "cologne", "cet", "cest", "central european time"], nil),
        ("Europe/Amsterdam", "Netherlands", ["netherlands", "holland", "amsterdam", "rotterdam"], nil),
        ("Europe/Brussels", "Belgium", ["belgium", "brussels"], nil),
        ("Europe/Zurich", "Switzerland", ["switzerland", "zurich", "geneva"], nil),
        ("Europe/Rome", "Italy", ["italy", "rome", "milan", "naples", "florence"], nil),
        ("Europe/Vienna", "Austria", ["austria", "vienna"], nil),
        ("Europe/Stockholm", "Sweden", ["sweden", "stockholm"], nil),
        ("Europe/Oslo", "Norway", ["norway", "oslo"], nil),
        ("Europe/Copenhagen", "Denmark", ["denmark", "copenhagen"], nil),
        ("Europe/Warsaw", "Poland", ["poland", "warsaw", "krakow"], nil),
        ("Europe/Prague", "Czechia", ["czechia", "czech republic", "prague"], nil),
        ("Europe/Helsinki", "Finland", ["finland", "helsinki"], nil),
        ("Europe/Athens", "Greece", ["greece", "athens", "eet", "eest"], nil),
        ("Europe/Istanbul", "Turkey", ["turkey", "istanbul", "ankara"], nil),
        ("Europe/Kyiv", "Ukraine", ["ukraine", "kyiv", "kiev"], nil),
        ("Europe/Moscow", "Moscow", ["russia", "moscow", "msk"], "Moscow time assumed"),
        ("Africa/Cairo", "Egypt", ["egypt", "cairo"], nil),
        ("Africa/Johannesburg", "South Africa", ["south africa", "johannesburg", "cape town", "sast"], nil),
        ("Africa/Lagos", "Nigeria", ["nigeria", "lagos"], nil),
        ("Africa/Nairobi", "Kenya", ["kenya", "nairobi"], nil),
        ("Asia/Dubai", "UAE", ["uae", "dubai", "abu dhabi", "united arab emirates"], nil),
        ("Asia/Riyadh", "Saudi Arabia", ["saudi arabia", "riyadh"], nil),
        ("Asia/Jerusalem", "Israel", ["israel", "tel aviv", "jerusalem"], nil),
        ("Asia/Karachi", "Pakistan", ["pakistan", "karachi", "lahore"], nil),
        ("Asia/Kolkata", "India", ["india", "ist", "mumbai", "delhi", "new delhi", "bangalore", "bengaluru", "chennai", "hyderabad", "kolkata", "pune"], nil),
        ("Asia/Dhaka", "Bangladesh", ["bangladesh", "dhaka"], nil),
        ("Asia/Bangkok", "Thailand", ["thailand", "bangkok"], nil),
        ("Asia/Ho_Chi_Minh", "Vietnam", ["vietnam", "hanoi", "ho chi minh city", "saigon"], nil),
        ("Asia/Jakarta", "Indonesia", ["indonesia", "jakarta"], "Western Indonesia assumed"),
        ("Asia/Singapore", "Singapore", ["singapore", "sgt"], nil),
        ("Asia/Kuala_Lumpur", "Malaysia", ["malaysia", "kuala lumpur"], nil),
        ("Asia/Manila", "Philippines", ["philippines", "manila"], nil),
        ("Asia/Hong_Kong", "Hong Kong", ["hong kong", "hk", "hkt"], nil),
        ("Asia/Shanghai", "China", ["china", "beijing", "shanghai", "shenzhen", "guangzhou"], nil),
        ("Asia/Taipei", "Taiwan", ["taiwan", "taipei"], nil),
        ("Asia/Seoul", "South Korea", ["korea", "south korea", "seoul", "kst"], nil),
        ("Asia/Tokyo", "Japan", ["japan", "tokyo", "osaka", "kyoto", "jst"], nil),
        ("Australia/Sydney", "Sydney", ["sydney", "new south wales", "nsw", "canberra", "aest", "aedt"], nil),
        ("Australia/Sydney", "Australia", ["australia"], "Australian Eastern assumed"),
        ("Australia/Melbourne", "Melbourne", ["melbourne", "victoria"], nil),
        ("Australia/Brisbane", "Brisbane", ["brisbane", "queensland"], nil),
        ("Australia/Adelaide", "Adelaide", ["adelaide", "south australia"], nil),
        ("Australia/Perth", "Perth", ["perth", "western australia", "awst"], nil),
        ("Pacific/Auckland", "New Zealand", ["new zealand", "nz", "auckland", "wellington", "nzst", "nzdt"], nil),
        ("UTC", "UTC", ["utc", "zulu", "z"], nil)
    ]

    private static let byAlias: [String: TimeZonePlace] = {
        var map: [String: TimeZonePlace] = [:]
        for row in table {
            let place = TimeZonePlace(name: row.name, zone: row.zone, note: row.note)
            for alias in row.aliases where map[alias] == nil { map[alias] = place }
        }
        // City names from the system's zone list, such as "Europe/Lisbon" → "lisbon".
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let city = identifier.split(separator: "/").last else { continue }
            let key = city.replacingOccurrences(of: "_", with: " ").lowercased()
            if map[key] == nil { map[key] = TimeZonePlace(name: key.capitalized, zone: identifier, note: nil) }
        }
        return map
    }()

    /// The place a name means, after "time", "timezone", and "the" are removed. Nil when unknown.
    public static func place(_ text: String) -> TimeZonePlace? {
        var words = text.lowercased()
            .replacingOccurrences(of: "?", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        if words.first == "the" { words.removeFirst() }
        if words.suffix(2) == ["time", "zone"] { words.removeLast(2) }
        while let last = words.last, ["time", "timezone", "zone"].contains(last) { words.removeLast() }
        guard !words.isEmpty else { return nil }
        return byAlias[words.joined(separator: " ")]
    }

    /// One entry per distinct place, for Jev to choose from. The ID is the IANA zone plus the name.
    public static var choices: [(id: String, title: String, detail: String)] {
        table.map { row in
            let sample = row.aliases.filter { $0.count > 3 }.prefix(8).joined(separator: ", ")
            return ("zone:" + row.zone + "|" + row.name, row.name, sample.isEmpty ? row.zone : "Also: " + sample)
        }
    }

    /// The place for a Jev choice ID. Only IDs from `choices` resolve.
    public static func place(forChoice id: String) -> TimeZonePlace? {
        table.first { "zone:" + $0.zone + "|" + $0.name == id }.map { TimeZonePlace(name: $0.name, zone: $0.zone, note: $0.note) }
    }

    /// Standard offset and labels for zones people know by letters. Others show "GMT+5:30".
    private static let labels: [String: (standard: Double, standardLabel: String, summerLabel: String)] = [
        "America/Los_Angeles": (-8, "PST", "PDT"), "America/Denver": (-7, "MST", "MDT"), "America/Phoenix": (-7, "MST", "MST"),
        "America/Chicago": (-6, "CST", "CDT"), "America/New_York": (-5, "EST", "EDT"), "America/Toronto": (-5, "EST", "EDT"),
        "America/Anchorage": (-9, "AKST", "AKDT"), "Pacific/Honolulu": (-10, "HST", "HST"), "America/Halifax": (-4, "AST", "ADT"),
        "Europe/London": (0, "GMT", "BST"), "Europe/Dublin": (0, "GMT", "IST"), "Europe/Lisbon": (0, "WET", "WEST"),
        "Europe/Paris": (1, "CET", "CEST"), "Europe/Madrid": (1, "CET", "CEST"), "Europe/Berlin": (1, "CET", "CEST"),
        "Europe/Amsterdam": (1, "CET", "CEST"), "Europe/Brussels": (1, "CET", "CEST"), "Europe/Zurich": (1, "CET", "CEST"),
        "Europe/Rome": (1, "CET", "CEST"), "Europe/Vienna": (1, "CET", "CEST"), "Europe/Stockholm": (1, "CET", "CEST"),
        "Europe/Oslo": (1, "CET", "CEST"), "Europe/Copenhagen": (1, "CET", "CEST"), "Europe/Warsaw": (1, "CET", "CEST"),
        "Europe/Prague": (1, "CET", "CEST"), "Europe/Helsinki": (2, "EET", "EEST"), "Europe/Athens": (2, "EET", "EEST"),
        "Europe/Kyiv": (2, "EET", "EEST"), "Europe/Moscow": (3, "MSK", "MSK"), "Africa/Johannesburg": (2, "SAST", "SAST"),
        "Asia/Kolkata": (5.5, "IST", "IST"), "Asia/Singapore": (8, "SGT", "SGT"), "Asia/Hong_Kong": (8, "HKT", "HKT"),
        "Asia/Tokyo": (9, "JST", "JST"), "Asia/Seoul": (9, "KST", "KST"), "Australia/Sydney": (10, "AEST", "AEDT"),
        "Australia/Melbourne": (10, "AEST", "AEDT"), "Australia/Brisbane": (10, "AEST", "AEST"), "Australia/Perth": (8, "AWST", "AWST"),
        "Pacific/Auckland": (12, "NZST", "NZDT"), "UTC": (0, "UTC", "UTC")
    ]

    /// A short label for a zone at a moment, such as "BST" or "GMT+5:30". It compares offsets, not
    /// the system's daylight flag, because Ireland's rules mark winter as the shifted time.
    public static func label(_ zone: TimeZone, at date: Date) -> String {
        let offset = zone.secondsFromGMT(for: date)
        if let known = labels[zone.identifier] {
            let standard = Int(known.standard * 3600)
            if offset == standard { return known.standardLabel }
            if offset == standard + 3600 { return known.summerLabel }
        }
        guard offset != 0 else { return "GMT" }
        let hours = abs(offset) / 3600, minutes = abs(offset) % 3600 / 60
        return "GMT" + (offset < 0 ? "-" : "+") + String(hours) + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }
}
