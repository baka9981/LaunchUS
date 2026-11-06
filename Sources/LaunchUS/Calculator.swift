import Foundation

/// Arithmetic and unit conversion typed into the search field, e.g. `12*(3+4)` or `10 km to mi`.
enum Calculator {
    struct Result: Equatable {
        /// What the query was read as, e.g. "10 km =".
        let expression: String
        /// The answer for display, grouped and with the unit.
        let display: String
        /// The answer to copy: plain digits, no grouping.
        let copyText: String
        /// Where the answer comes from, e.g. the date of an exchange rate.
        var note: String? = nil
    }

    /// `rates`: units of each currency per euro, when currency conversion is on.
    static func evaluate(_ query: String, rates: CurrencyRates.Table? = nil) -> Result? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 200, text.contains(where: \.isNumber) else { return nil }
        if let conversion = convert(text) { return conversion }
        if let rates, let money = convertCurrency(text, rates: rates) { return money }
        return arithmetic(text)
    }

    // MARK: - Currency

    /// Names and symbols people type for the common currencies, besides the ISO codes.
    static let currencyNames: [String: String] = [
        "$": "USD", "us$": "USD", "美元": "USD", "美金": "USD", "刀": "USD",
        "¥": "CNY", "￥": "CNY", "rmb": "CNY", "人民币": "CNY", "元": "CNY", "块": "CNY",
        "€": "EUR", "欧元": "EUR", "£": "GBP", "英镑": "GBP",
        "日元": "JPY", "円": "JPY", "日币": "JPY", "港币": "HKD", "港元": "HKD", "hk$": "HKD",
        "韩元": "KRW", "₩": "KRW", "台币": "TWD", "新台币": "TWD", "nt$": "TWD",
        "澳元": "AUD", "a$": "AUD", "加元": "CAD", "c$": "CAD", "瑞郎": "CHF", "瑞士法郎": "CHF",
        "新加坡元": "SGD", "新元": "SGD", "s$": "SGD", "泰铢": "THB", "卢比": "INR", "₹": "INR",
        "卢布": "RUB", "₽": "RUB", "澳门元": "MOP", "新西兰元": "NZD", "林吉特": "MYR", "比索": "MXN",
        "瑞典克朗": "SEK", "挪威克朗": "NOK", "丹麦克朗": "DKK", "里拉": "TRY", "雷亚尔": "BRL", "兰特": "ZAR",
    ]

    private static func currencyCode(_ name: String, rates: CurrencyRates.Table) -> String? {
        let code = currencyNames[name] ?? name.uppercased()
        return code.count == 3 && rates.rates[code] != nil ? code : nil
    }

    /// `100 usd to cny`, `$100 in eur`, `100美元换人民币`.
    static func convertCurrency(_ text: String, rates: CurrencyRates.Table) -> Result? {
        let lower = text.lowercased()
        for separator in separators {
            guard let range = lower.range(of: separator) else { continue }
            let left = lower[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let target = currencyCode(right, rates: rates),
                  let (number, source) = splitCurrency(left, rates: rates),
                  let from = rates.rates[source], let to = rates.rates[target], from > 0 else { continue }
            let value = number / from * to
            guard value.isFinite else { return nil }
            return Result(expression: "\(format(number, grouped: true)) \(source) =",
                          display: "\(money(value, grouped: true)) \(target)",
                          copyText: money(value, grouped: false),
                          note: String(localized: "汇率 \(rates.date) · 欧洲央行"))
        }
        return nil
    }

    private static func splitCurrency(_ text: String, rates: CurrencyRates.Table) -> (Double, String)? {
        let names = (Array(currencyNames.keys) + rates.rates.keys.map { $0.lowercased() }).sorted { $0.count > $1.count }
        for name in names {
            let rest: String
            if text.hasSuffix(name) { rest = String(text.dropLast(name.count)) }
            else if text.hasPrefix(name) { rest = String(text.dropFirst(name.count)) }
            else { continue }
            let numberPart = rest.trimmingCharacters(in: .whitespaces)
            guard !numberPart.isEmpty, let code = currencyCode(name, rates: rates) else { continue }
            if let plain = Double(numberPart.replacingOccurrences(of: ",", with: "")) { return (plain, code) }
            var parser = Parser(numberPart)
            if let value = parser.parse() { return (value, code) }
        }
        return nil
    }

    /// Two decimals, or more for small amounts so they don't show as 0.00.
    static func money(_ value: Double, grouped: Bool) -> String {
        let style = FloatingPointFormatStyle<Double>.number
            .precision(abs(value) >= 1 || value == 0 ? .fractionLength(2) : .significantDigits(1...4))
            .grouping(grouped ? .automatic : .never)
            .locale(Locale(identifier: "en_US"))
        return value.formatted(style)
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

    // MARK: - Units

    private enum Kind { case length, mass, temperature, volume, speed, data, duration, area }

    private static let units: [String: (Kind, Dimension)] = {
        var table: [String: (Kind, Dimension)] = [:]
        func add(_ kind: Kind, _ unit: Dimension, _ names: String...) {
            for name in names { table[name] = (kind, unit) }
        }
        add(.length, UnitLength.millimeters, "mm", "毫米")
        add(.length, UnitLength.centimeters, "cm", "厘米")
        add(.length, UnitLength.meters, "m", "米", "meter", "meters")
        add(.length, UnitLength.kilometers, "km", "公里", "千米")
        add(.length, UnitLength.inches, "in", "inch", "inches", "英寸", "\"")
        add(.length, UnitLength.feet, "ft", "feet", "foot", "英尺")
        add(.length, UnitLength.yards, "yd", "yard", "yards", "码")
        add(.length, UnitLength.miles, "mi", "mile", "miles", "英里")
        add(.length, UnitLength.nauticalMiles, "nmi", "海里")
        add(.mass, UnitMass.milligrams, "mg", "毫克")
        add(.mass, UnitMass.grams, "g", "克")
        add(.mass, UnitMass.kilograms, "kg", "公斤", "千克")
        add(.mass, UnitMass(symbol: "斤", converter: UnitConverterLinear(coefficient: 0.5)), "斤")
        add(.mass, UnitMass.metricTons, "t", "吨")
        add(.mass, UnitMass.ounces, "oz", "盎司")
        add(.mass, UnitMass.pounds, "lb", "lbs", "磅")
        add(.temperature, UnitTemperature.celsius, "c", "°c", "℃", "摄氏度")
        add(.temperature, UnitTemperature.fahrenheit, "f", "°f", "℉", "华氏度")
        add(.temperature, UnitTemperature.kelvin, "k", "开尔文")
        add(.volume, UnitVolume.milliliters, "ml", "毫升")
        add(.volume, UnitVolume.liters, "l", "升")
        add(.volume, UnitVolume.gallons, "gal", "加仑")
        add(.volume, UnitVolume.fluidOunces, "floz", "fl oz")
        add(.volume, UnitVolume.cups, "cup", "cups", "杯")
        add(.speed, UnitSpeed.kilometersPerHour, "km/h", "kmh", "kph")
        add(.speed, UnitSpeed.milesPerHour, "mph")
        add(.speed, UnitSpeed.metersPerSecond, "m/s")
        add(.speed, UnitSpeed.knots, "kn", "节")
        add(.data, UnitInformationStorage.bytes, "b", "byte", "bytes", "字节")
        add(.data, UnitInformationStorage.kilobytes, "kb")
        add(.data, UnitInformationStorage.megabytes, "mb")
        add(.data, UnitInformationStorage.gigabytes, "gb")
        add(.data, UnitInformationStorage.terabytes, "tb")
        add(.data, UnitInformationStorage.kibibytes, "kib")
        add(.data, UnitInformationStorage.mebibytes, "mib")
        add(.data, UnitInformationStorage.gibibytes, "gib")
        add(.duration, UnitDuration.seconds, "s", "sec", "秒")
        add(.duration, UnitDuration.minutes, "min", "分钟")
        add(.duration, UnitDuration.hours, "h", "hr", "hours", "小时")
        add(.duration, UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "d", "day", "days", "天")
        add(.area, UnitArea.squareMeters, "m2", "m²", "平方米")
        add(.area, UnitArea.squareKilometers, "km2", "km²", "平方公里")
        add(.area, UnitArea.squareFeet, "ft2", "ft²", "平方英尺")
        add(.area, UnitArea.acres, "acre", "acres", "英亩")
        add(.area, UnitArea.hectares, "ha", "公顷")
        add(.area, UnitArea(symbol: "亩", converter: UnitConverterLinear(coefficient: 2000.0 / 3)), "亩")
        return table
    }()

    private static let separators = [" to ", " in ", " as ", "=", "->", "→", "转换成", "换算成", "换成", "转成", "等于多少", "是多少", "转", "换"]

    /// `<number> <unit> to <unit>`; the number may itself be a sum, e.g. `3*12 in to cm`.
    static func convert(_ text: String) -> Result? {
        let lower = text.lowercased()
        for separator in separators {
            guard let range = lower.range(of: separator) else { continue }
            let left = lower[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let target = units[right], let (number, source, name) = splitUnit(left),
                  source.0 == target.0 else { continue }
            let value = Measurement(value: number, unit: source.1).converted(to: target.1).value
            guard value.isFinite else { return nil }
            let shown = "\(format(number, grouped: true)) \(name)"
            return Result(expression: "\(shown) =", display: "\(format(value, grouped: true)) \(right)",
                          copyText: format(value, grouped: false))
        }
        return nil
    }

    private static let unitNamesLongestFirst = units.keys.sorted { $0.count > $1.count }

    /// "10km", "10 km", "-3.5 °c", "2 km2" → number, unit and the unit as typed.
    private static func splitUnit(_ text: String) -> (Double, (Kind, Dimension), String)? {
        for name in unitNamesLongestFirst where text.hasSuffix(name) {
            let numberPart = text.dropLast(name.count).trimmingCharacters(in: .whitespaces)
            guard !numberPart.isEmpty, let unit = units[name] else { continue }
            if let plain = Double(numberPart.replacingOccurrences(of: ",", with: "")) { return (plain, unit, name) }
            var parser = Parser(numberPart)
            if let value = parser.parse() { return (value, unit, name) }
        }
        return nil
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
