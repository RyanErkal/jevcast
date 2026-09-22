import Foundation

/// Converts `<amount> <unit> in|to|as <unit>` with Foundation measurements.
/// Both units must belong to one dimension. Currency is not supported.
enum UnitConversion {
    struct Entry {
        let unit: Dimension
        let symbol: String
    }

    private static let connectors = [" in ", " to ", " as ", " into ", "->", "→"]

    static func evaluate(_ text: String, separators: Calculator.Separators) -> String? {
        let lower = text.lowercased()
        guard lower.contains(where: \.isLetter) else { return nil }

        // Every split is tried, because "in" is also a unit: "12 in in cm".
        for connector in connectors {
            var searchStart = lower.startIndex
            while let range = lower.range(of: connector, range: searchStart..<lower.endIndex) {
                searchStart = lower.index(after: range.lowerBound)
                guard let target = entry(String(lower[range.upperBound...])),
                      let (amount, source) = amountAndUnit(String(lower[..<range.lowerBound]), separators: separators),
                      type(of: source.unit).baseUnit() == type(of: target.unit).baseUnit() else { continue }
                let converted = Measurement(value: amount, unit: source.unit).converted(to: target.unit).value
                guard let value = Calculator.bounded(converted) else { return nil }
                return format(value, separators: separators) + " " + target.symbol
            }
        }
        return nil
    }

    private static func amountAndUnit(_ text: String, separators: Calculator.Separators) -> (Double, Entry)? {
        guard let start = text.firstIndex(where: { $0.isLetter || $0 == "°" }),
              let source = entry(String(text[start...])) else { return nil }
        let amountText = String(text[..<start])
        guard !amountText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var parser = Calculator.Parser(amountText, separators: separators)
        return parser.parse().map { ($0, source) }
    }

    private static func entry(_ name: String) -> Entry? {
        let key = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return units[key]
    }

    // Up to four decimals keep conversions readable; tiny values keep
    // four significant digits instead of rounding to zero.
    private static func format(_ value: Double, separators: Calculator.Separators) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        guard rounded != 0 || value == 0 else {
            return separators.localize(String(format: "%.4g", value))
        }
        guard rounded != rounded.rounded() else { return Calculator.format(rounded, separators: separators) }
        var text = String(format: "%.4f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return separators.localize(text)
    }

    private static func linear<T: Dimension>(_ type: T.Type, _ symbol: String, _ coefficient: Double) -> T {
        T(symbol: symbol, converter: UnitConverterLinear(coefficient: coefficient))
    }

    // Foundation rounds some coefficients (km/h is 0.277778); these are exact.
    private static let day = linear(UnitDuration.self, "d", 86_400)
    private static let week = linear(UnitDuration.self, "wk", 604_800)
    private static let pounds = linear(UnitMass.self, "lb", 0.45359237)
    private static let ounces = linear(UnitMass.self, "oz", 0.028349523125)
    private static let stones = linear(UnitMass.self, "st", 6.35029318)
    private static let kilometersPerHour = linear(UnitSpeed.self, "km/h", 1 / 3.6)
    private static let knots = linear(UnitSpeed.self, "kn", 1_852 / 3_600)
    private static let gallons = linear(UnitVolume.self, "gal", 3.785411784)
    private static let quarts = linear(UnitVolume.self, "qt", 0.946352946)
    private static let pints = linear(UnitVolume.self, "pt", 0.473176473)
    private static let fluidOunces = linear(UnitVolume.self, "fl oz", 0.0295735295625)
    private static let tablespoons = linear(UnitVolume.self, "tbsp", 0.01478676478125)
    private static let teaspoons = linear(UnitVolume.self, "tsp", 0.00492892159375)

    private static let units: [String: Entry] = {
        var table: [String: Entry] = [:]
        func add(_ unit: Dimension, _ symbol: String, _ names: [String]) {
            for name in names + [symbol.lowercased()] { table[name] = Entry(unit: unit, symbol: symbol) }
        }
        add(UnitLength.millimeters, "mm", ["millimeter", "millimeters", "millimetre", "millimetres"])
        add(UnitLength.centimeters, "cm", ["centimeter", "centimeters", "centimetre", "centimetres"])
        add(UnitLength.meters, "m", ["meter", "meters", "metre", "metres"])
        add(UnitLength.kilometers, "km", ["kilometer", "kilometers", "kilometre", "kilometres", "kms"])
        add(UnitLength.inches, "in", ["inch", "inches"])
        add(UnitLength.feet, "ft", ["foot", "feet"])
        add(UnitLength.yards, "yd", ["yard", "yards", "yds"])
        add(UnitLength.miles, "mi", ["mile", "miles"])
        add(UnitLength.nauticalMiles, "nmi", ["nautical mile", "nautical miles"])

        add(UnitMass.milligrams, "mg", ["milligram", "milligrams"])
        add(UnitMass.grams, "g", ["gram", "grams"])
        add(UnitMass.kilograms, "kg", ["kilogram", "kilograms", "kgs", "kilo", "kilos"])
        add(UnitMass.metricTons, "t", ["tonne", "tonnes", "metric ton", "metric tons"])
        add(ounces, "oz", ["ounce", "ounces"])
        add(pounds, "lb", ["lbs", "pound", "pounds"])
        add(stones, "st", ["stone", "stones"])

        add(UnitTemperature.celsius, "°C", ["c", "celsius", "centigrade", "° c", "deg c", "degc"])
        add(UnitTemperature.fahrenheit, "°F", ["f", "fahrenheit", "° f", "deg f", "degf"])
        add(UnitTemperature.kelvin, "K", ["kelvin"])

        add(UnitDuration.milliseconds, "ms", ["millisecond", "milliseconds"])
        add(UnitDuration.seconds, "s", ["sec", "secs", "second", "seconds"])
        add(UnitDuration.minutes, "min", ["mins", "minute", "minutes"])
        add(UnitDuration.hours, "h", ["hr", "hrs", "hour", "hours"])
        add(day, "d", ["day", "days"])
        add(week, "wk", ["wks", "week", "weeks"])

        add(UnitInformationStorage.bits, "bit", ["bits"])
        add(UnitInformationStorage.bytes, "B", ["byte", "bytes"])
        add(UnitInformationStorage.kilobytes, "KB", ["kilobyte", "kilobytes"])
        add(UnitInformationStorage.megabytes, "MB", ["megabyte", "megabytes"])
        add(UnitInformationStorage.gigabytes, "GB", ["gigabyte", "gigabytes"])
        add(UnitInformationStorage.terabytes, "TB", ["terabyte", "terabytes"])
        add(UnitInformationStorage.petabytes, "PB", ["petabyte", "petabytes"])
        add(UnitInformationStorage.kibibytes, "KiB", ["kibibyte", "kibibytes"])
        add(UnitInformationStorage.mebibytes, "MiB", ["mebibyte", "mebibytes"])
        add(UnitInformationStorage.gibibytes, "GiB", ["gibibyte", "gibibytes"])
        add(UnitInformationStorage.tebibytes, "TiB", ["tebibyte", "tebibytes"])
        add(UnitInformationStorage.megabits, "Mbit", ["megabit", "megabits", "mbps"])
        add(UnitInformationStorage.gigabits, "Gbit", ["gigabit", "gigabits", "gbps"])

        add(UnitVolume.milliliters, "mL", ["ml", "milliliter", "milliliters", "millilitre", "millilitres"])
        add(UnitVolume.centiliters, "cL", ["centiliter", "centiliters", "centilitre", "centilitres"])
        add(UnitVolume.liters, "L", ["l", "liter", "liters", "litre", "litres"])
        add(UnitVolume.cubicMeters, "m³", ["m3", "cubic meter", "cubic meters", "cubic metre", "cubic metres"])
        add(teaspoons, "tsp", ["teaspoon", "teaspoons"])
        add(tablespoons, "tbsp", ["tablespoon", "tablespoons"])
        add(fluidOunces, "fl oz", ["floz", "fluid ounce", "fluid ounces"])
        add(UnitVolume.cups, "cup", ["cups"])
        add(pints, "pt", ["pint", "pints"])
        add(quarts, "qt", ["quart", "quarts"])
        add(gallons, "gal", ["gallon", "gallons"])
        add(UnitVolume.imperialGallons, "imp gal", ["imperial gallon", "imperial gallons"])

        add(UnitSpeed.metersPerSecond, "m/s", ["mps", "meters per second", "metres per second"])
        add(kilometersPerHour, "km/h", ["kmh", "kph", "kilometers per hour", "kilometres per hour"])
        add(UnitSpeed.milesPerHour, "mph", ["mi/h", "miles per hour"])
        add(knots, "kn", ["knot", "knots", "kt", "kts"])

        add(UnitArea.squareMillimeters, "mm²", ["mm2", "sq mm"])
        add(UnitArea.squareCentimeters, "cm²", ["cm2", "sq cm"])
        add(UnitArea.squareMeters, "m²", ["m2", "sq m", "square meter", "square meters", "square metre", "square metres"])
        add(UnitArea.squareKilometers, "km²", ["km2", "sq km", "square kilometer", "square kilometers", "square kilometre", "square kilometres"])
        add(UnitArea.squareInches, "in²", ["in2", "sq in", "square inch", "square inches"])
        add(UnitArea.squareFeet, "ft²", ["ft2", "sq ft", "square foot", "square feet"])
        add(UnitArea.squareMiles, "mi²", ["mi2", "sq mi", "square mile", "square miles"])
        add(UnitArea.acres, "ac", ["acre", "acres"])
        add(UnitArea.hectares, "ha", ["hectare", "hectares"])
        return table
    }()
}
