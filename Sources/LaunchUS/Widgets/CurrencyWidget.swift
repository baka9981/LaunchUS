import Foundation
import SwiftUI

// Exchange rates: what one unit of a few currencies is worth in yours. The rates are the
// day's reference rates, fetched at most once an hour and kept for when the Mac is offline.

/// Which currencies one widget shows. Nil fields follow the Mac's region.
struct Currencies: Codable, Equatable {
    var base: String?
    var shown: [String]?

    static let common = ["CNY", "USD", "EUR", "JPY", "HKD", "GBP", "KRW", "TWD", "SGD", "AUD", "CAD", "CHF",
                         "NZD", "MOP", "THB", "MYR", "VND", "PHP", "IDR", "INR", "AED", "RUB", "SEK", "BRL"]

    var resolvedBase: String {
        if let base { return base }
        let local = Locale.current.currency?.identifier ?? "USD"
        return Self.common.contains(local) ? local : "USD"
    }

    var resolvedShown: [String] {
        let base = resolvedBase
        return (shown ?? ["USD", "CNY", "EUR", "JPY", "HKD", "GBP", "KRW", "TWD"]).filter { $0 != base }
    }

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code) ?? code
    }

    /// The flag of the place the currency belongs to: the code's first two letters, which
    /// for EUR gives the European flag.
    static func flag(_ code: String) -> String {
        // Some regions' fonts draw this flag as an empty box.
        if code == "TWD" { return "🪙" }
        return String(String.UnicodeScalarView(code.prefix(2).unicodeScalars.compactMap { Unicode.Scalar(127397 + $0.value) }))
    }
}

/// The day's rates against the US dollar, shared by every exchange-rate widget.
@MainActor @Observable
final class CurrencyRates {
    static let shared = CurrencyRates()

    private(set) var rates: [String: Double] = [:]
    private(set) var updated: Date?
    private(set) var failed = false
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var lastTry: Date?

    private static let ratesKey = "currencyRates"
    private static let updatedKey = "currencyRatesUpdated"

    init() {
        rates = UserDefaults.standard.dictionary(forKey: Self.ratesKey) as? [String: Double] ?? [:]
        updated = UserDefaults.standard.object(forKey: Self.updatedKey) as? Date
    }

    /// One unit of `code` in `base`, or nil before the first fetch.
    func value(of code: String, in base: String) -> Double? {
        guard let from = rates[code], let to = rates[base], from > 0 else { return nil }
        return to / from
    }

    /// Fetches when the rates are over an hour old; `force` for a click on the card.
    func refreshIfNeeded(force: Bool = false) {
        guard !fetching else { return }
        let now = Date()
        if !force {
            if let updated, now.timeIntervalSince(updated) < 3600 { return }
            // Offline: don't hammer, try again in a few minutes.
            if let lastTry, now.timeIntervalSince(lastTry) < 300 { return }
        }
        fetching = true
        lastTry = now
        Task {
            let fetched = await Self.fetch()
            fetching = false
            guard let fetched, !fetched.isEmpty else {
                failed = true
                return
            }
            failed = false
            rates = fetched
            updated = Date()
            UserDefaults.standard.set(fetched, forKey: Self.ratesKey)
            UserDefaults.standard.set(updated, forKey: Self.updatedKey)
        }
    }

    /// open.er-api.com first, a copy of the same reference rates on jsDelivr if that fails.
    private nonisolated static func fetch() async -> [String: Double]? {
        if let url = URL(string: "https://open.er-api.com/v6/latest/USD"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["result"] as? String == "success",
           let rates = json["rates"] as? [String: Any] {
            return rates.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
        if let url = URL(string: "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rates = json["usd"] as? [String: Any] {
            var out: [String: Double] = [:]
            for (code, value) in rates where code.count == 3 {
                if let v = (value as? NSNumber)?.doubleValue { out[code.uppercased()] = v }
            }
            return out
        }
        return nil
    }
}

struct CurrencyWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let live: Bool

    /// Small currencies read better a hundred at a time: 100 JPY rather than 1.
    static func quote(_ code: String, in base: String) -> (amount: Int, value: Double)? {
        guard let one = CurrencyRates.shared.value(of: code, in: base) else { return nil }
        return one < 0.05 ? (100, one * 100) : (1, one)
    }

    static func format(_ value: Double) -> String {
        let digits = value >= 1000 ? 0 : value >= 10 ? 2 : 4
        return value.formatted(.number.precision(.fractionLength(digits)))
    }

    private var rows: Int {
        switch size {
        case .small: 1
        case .medium: 3
        case .large: 8
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 600 : 3600)) { _ in
            let settings = WidgetStore.shared.currencies(id)
            let base = settings.resolvedBase
            let shown = Array(settings.resolvedShown.prefix(rows))
            let rates = CurrencyRates.shared
            VStack(alignment: .leading, spacing: unit * 0.08) {
                HStack(spacing: unit * 0.05) {
                    Image(systemName: "dollarsign.arrow.circlepath").font(.system(size: unit * 0.12, weight: .semibold))
                    Text(String(localized: "汇率")).font(.system(size: unit * 0.13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(verbatim: "\(Currencies.flag(base)) \(base)")
                        .font(.system(size: unit * 0.11, weight: .medium)).opacity(0.65)
                }
                if rates.rates.isEmpty {
                    Spacer(minLength: 0)
                    Text(rates.failed ? String(localized: "暂时无法获取汇率，点一下重试") : String(localized: "正在获取汇率…"))
                        .font(.system(size: unit * 0.11, weight: .medium)).opacity(0.65)
                        .fixedSize(horizontal: false, vertical: true)
                } else if shown.isEmpty {
                    Spacer(minLength: 0)
                    Text(String(localized: "右键选择要显示的货币"))
                        .font(.system(size: unit * 0.11, weight: .medium)).opacity(0.65)
                } else if size == .small, let code = shown.first {
                    small(code, base: base)
                } else {
                    VStack(spacing: size == .large ? unit * 0.1 : unit * 0.07) {
                        ForEach(shown, id: \.self) { code in row(code, base: base) }
                    }
                    Spacer(minLength: 0)
                    if size == .large, let updated = rates.updated {
                        Text(String(localized: "更新于 \(updated.formatted(date: .abbreviated, time: .shortened))"))
                            .font(.system(size: unit * 0.09)).opacity(0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { rates.refreshIfNeeded() }
            .task(id: live) { if live { rates.refreshIfNeeded() } }
        }
    }

    private func small(_ code: String, base: String) -> some View {
        let quote = Self.quote(code, in: base)
        return VStack(alignment: .leading, spacing: unit * 0.03) {
            Spacer(minLength: 0)
            Text(verbatim: "\(Currencies.flag(code)) \(quote?.amount ?? 1) \(code)")
                .font(.system(size: unit * 0.13, weight: .medium)).opacity(0.75)
            Text(verbatim: quote.map { Self.format($0.value) } ?? "–")
                .font(.system(size: unit * 0.3, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(Currencies.name(base)).font(.system(size: unit * 0.1)).opacity(0.6).lineLimit(1)
        }
    }

    private func row(_ code: String, base: String) -> some View {
        let quote = Self.quote(code, in: base)
        return HStack(spacing: unit * 0.08) {
            Text(verbatim: Currencies.flag(code)).font(.system(size: unit * 0.16))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(quote?.amount ?? 1) \(code)").font(.system(size: unit * 0.12, weight: .semibold))
                if size == .large {
                    Text(Currencies.name(code)).font(.system(size: unit * 0.09)).opacity(0.55).lineLimit(1)
                }
            }
            Spacer(minLength: unit * 0.1)
            Text(verbatim: quote.map { Self.format($0.value) } ?? "–")
                .font(.system(size: unit * 0.15, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).fixedSize().layoutPriority(1)
        }
    }
}
