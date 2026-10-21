import Foundation

/// Unit conversion for queries like "10 km in mi", "72f to c", "5 GB in MB". Pure Foundation, never traps.
enum CommandBarUnits {
    struct Output: Equatable {
        let title: String       // "6.21371 mi"
        let plain: String       // "6.21371"
        let subtitle: String    // "10 km = 6.21371 mi"
    }

    private struct Def { let category: String; let unit: Dimension; let symbol: String }

    private static let separators: Set<String> = ["in", "to", "as", "into", "->", "=", "=>"]

    static func convert(_ raw: String) -> Output? {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, q.count <= 80 else { return nil }
        let (number, rest) = splitNumber(q.replacingOccurrences(of: "°", with: " ").lowercased())
        guard let value = number, value.isFinite else { return nil }
        let words = rest.replacingOccurrences(of: "->", with: " -> ").replacingOccurrences(of: "=>", with: " => ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.count >= 2, words.count <= 8 else { return nil }
        // Try every split point; the first one where both sides are units of one category wins.
        for i in 1..<words.count where separators.contains(words[i]) {
            let left = words[0..<i].joined(separator: " ")
            let right = words[(i + 1)...].joined(separator: " ")
            guard !right.isEmpty, let a = lookup(left), let b = lookup(right), a.category == b.category else { continue }
            let m = Measurement(value: value, unit: a.unit).converted(to: b.unit)
            guard m.value.isFinite else { return nil }
            let out = fmt(m.value)
            let from = fmt(value)
            return Output(title: "\(out) \(b.symbol)", plain: out, subtitle: "\(from) \(a.symbol) = \(out) \(b.symbol)")
        }
        return nil
    }

    // MARK: Parsing

    /// "10km" -> (10, "km"); "-5.5 c to f" -> (-5.5, "c to f"); "km" -> (nil, ...).
    private static func splitNumber(_ s: String) -> (Double?, String) {
        let chars = Array(s)
        var i = 0
        if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
        let start = i
        var dot = false
        while i < chars.count, chars[i].isASCII, chars[i].isNumber || (chars[i] == "." && !dot) || chars[i] == "," {
            if chars[i] == "." { dot = true }
            i += 1
        }
        guard i > start else { return (nil, s) }
        let text = String(chars[0..<i]).replacingOccurrences(of: ",", with: "")
        guard let v = Double(text) else { return (nil, s) }
        return (v, String(chars[i...]).trimmingCharacters(in: .whitespaces))
    }

    private static func fmt(_ v: Double) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e12 || a < 1e-6 { return String(format: "%.6g", v) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumSignificantDigits = 8
        f.maximumFractionDigits = 6
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.6g", v)
    }

    private static func lookup(_ s: String) -> Def? {
        let key = s.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if let d = table[key] { return d }
        // crude plural fallback
        if key.hasSuffix("s"), let d = table[String(key.dropLast())] { return d }
        return nil
    }

    // MARK: Table

    private static let table: [String: Def] = {
        var t: [String: Def] = [:]
        func add(_ cat: String, _ unit: Dimension, _ symbol: String, _ names: [String]) {
            let d = Def(category: cat, unit: unit, symbol: symbol)
            for n in names { t[n] = d }
        }
        // Length
        add("length", UnitLength.meters, "m", ["m", "meter", "meters", "metre", "metres"])
        add("length", UnitLength.kilometers, "km", ["km", "kilometer", "kilometers", "kilometre", "kilometres"])
        add("length", UnitLength.centimeters, "cm", ["cm", "centimeter", "centimeters", "centimetre", "centimetres"])
        add("length", UnitLength.millimeters, "mm", ["mm", "millimeter", "millimeters", "millimetre", "millimetres"])
        add("length", UnitLength.miles, "mi", ["mi", "mile", "miles"])
        add("length", UnitLength.yards, "yd", ["yd", "yds", "yard", "yards"])
        add("length", UnitLength.feet, "ft", ["ft", "foot", "feet", "'"])
        add("length", UnitLength.inches, "in", ["in", "inch", "inches", "\""])
        add("length", UnitLength.nauticalMiles, "nmi", ["nmi", "nautical mile", "nautical miles"])
        // Mass
        add("mass", UnitMass.kilograms, "kg", ["kg", "kgs", "kilogram", "kilograms", "kilo", "kilos"])
        add("mass", UnitMass.grams, "g", ["g", "gram", "grams"])
        add("mass", UnitMass.milligrams, "mg", ["mg", "milligram", "milligrams"])
        add("mass", UnitMass.pounds, "lb", ["lb", "lbs", "pound", "pounds"])
        add("mass", UnitMass.ounces, "oz", ["oz", "ounce", "ounces"])
        add("mass", UnitMass.stones, "st", ["st", "stone", "stones"])
        add("mass", UnitMass.metricTons, "t", ["t", "tonne", "tonnes", "metric ton", "metric tons"])
        // Temperature
        add("temperature", UnitTemperature.celsius, "°C", ["c", "celsius", "centigrade"])
        add("temperature", UnitTemperature.fahrenheit, "°F", ["f", "fahrenheit"])
        add("temperature", UnitTemperature.kelvin, "K", ["k", "kelvin"])
        // Volume
        add("volume", UnitVolume.liters, "L", ["l", "liter", "liters", "litre", "litres"])
        add("volume", UnitVolume.milliliters, "mL", ["ml", "milliliter", "milliliters", "millilitre", "millilitres"])
        add("volume", UnitVolume.gallons, "gal", ["gal", "gallon", "gallons"])
        add("volume", UnitVolume.quarts, "qt", ["qt", "quart", "quarts"])
        add("volume", UnitVolume.pints, "pt", ["pt", "pint", "pints"])
        add("volume", UnitVolume.cups, "cup", ["cup", "cups"])
        add("volume", UnitVolume.fluidOunces, "fl oz", ["fl oz", "floz", "fluid ounce", "fluid ounces"])
        add("volume", UnitVolume.tablespoons, "tbsp", ["tbsp", "tablespoon", "tablespoons"])
        add("volume", UnitVolume.teaspoons, "tsp", ["tsp", "teaspoon", "teaspoons"])
        // Area
        add("area", UnitArea.squareMeters, "m²", ["sqm", "m2", "m²", "square meter", "square meters", "square metre", "square metres"])
        add("area", UnitArea.squareKilometers, "km²", ["sqkm", "km2", "km²", "square kilometer", "square kilometers"])
        add("area", UnitArea.squareFeet, "ft²", ["sqft", "ft2", "ft²", "square foot", "square feet"])
        add("area", UnitArea.squareMiles, "mi²", ["sqmi", "mi2", "mi²", "square mile", "square miles"])
        add("area", UnitArea.acres, "ac", ["ac", "acre", "acres"])
        add("area", UnitArea.hectares, "ha", ["ha", "hectare", "hectares"])
        // Speed
        add("speed", UnitSpeed.kilometersPerHour, "km/h", ["kmh", "kph", "km/h", "kilometers per hour", "kilometres per hour"])
        add("speed", UnitSpeed.milesPerHour, "mph", ["mph", "mi/h", "miles per hour"])
        add("speed", UnitSpeed.metersPerSecond, "m/s", ["mps", "m/s", "meters per second", "metres per second"])
        add("speed", UnitSpeed.knots, "kn", ["kn", "kt", "knot", "knots"])
        // Duration
        add("duration", UnitDuration.seconds, "s", ["s", "sec", "secs", "second", "seconds"])
        add("duration", UnitDuration.minutes, "min", ["min", "mins", "minute", "minutes"])
        add("duration", UnitDuration.hours, "h", ["h", "hr", "hrs", "hour", "hours"])
        add("duration", UnitDuration.milliseconds, "ms", ["ms", "millisecond", "milliseconds"])
        add("duration", DayUnit.day, "days", ["d", "day", "days"])
        add("duration", DayUnit.week, "weeks", ["wk", "wks", "week", "weeks"])
        // Data
        add("data", UnitInformationStorage.bytes, "B", ["b", "byte", "bytes"])
        add("data", UnitInformationStorage.kilobytes, "KB", ["kb", "kilobyte", "kilobytes"])
        add("data", UnitInformationStorage.megabytes, "MB", ["mb", "megabyte", "megabytes"])
        add("data", UnitInformationStorage.gigabytes, "GB", ["gb", "gigabyte", "gigabytes", "gig", "gigs"])
        add("data", UnitInformationStorage.terabytes, "TB", ["tb", "terabyte", "terabytes"])
        add("data", UnitInformationStorage.petabytes, "PB", ["pb", "petabyte", "petabytes"])
        add("data", UnitInformationStorage.kibibytes, "KiB", ["kib", "kibibyte", "kibibytes"])
        add("data", UnitInformationStorage.mebibytes, "MiB", ["mib", "mebibyte", "mebibytes"])
        add("data", UnitInformationStorage.gibibytes, "GiB", ["gib", "gibibyte", "gibibytes"])
        add("data", UnitInformationStorage.tebibytes, "TiB", ["tib", "tebibyte", "tebibytes"])
        add("data", UnitInformationStorage.bits, "bit", ["bit", "bits"])
        add("data", UnitInformationStorage.megabits, "Mb", ["mbit", "mbits", "megabit", "megabits", "mbps"])
        add("data", UnitInformationStorage.gigabits, "Gb", ["gbit", "gbits", "gigabit", "gigabits"])
        // Energy / pressure / angle
        add("energy", UnitEnergy.kilojoules, "kJ", ["kj", "kilojoule", "kilojoules"])
        add("energy", UnitEnergy.joules, "J", ["j", "joule", "joules"])
        add("energy", UnitEnergy.kilocalories, "kcal", ["kcal", "calorie", "calories", "cal"])
        add("energy", UnitEnergy.kilowattHours, "kWh", ["kwh", "kilowatt hour", "kilowatt hours"])
        add("pressure", UnitPressure.bars, "bar", ["bar", "bars"])
        add("pressure", UnitPressure.poundsForcePerSquareInch, "psi", ["psi"])
        add("pressure", UnitPressure.kilopascals, "kPa", ["kpa", "kilopascal", "kilopascals"])
        add("pressure", UnitPressure.hectopascals, "hPa", ["hpa", "hectopascal"])
        add("angle", UnitAngle.degrees, "°", ["deg", "degree", "degrees"])
        add("angle", UnitAngle.radians, "rad", ["rad", "radian", "radians"])
        return t
    }()
}

/// Day / week as `UnitDuration` values (Foundation has no built-in constants for them).
private enum DayUnit {
    static let day = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400))
    static let week = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
}
