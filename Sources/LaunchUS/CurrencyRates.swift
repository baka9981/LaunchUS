import Foundation
import Observation

/// Exchange rates for the calculator, from the European Central Bank by way of
/// frankfurter.app. Fetched only while "汇率换算" is on, at most twice a day; the request
/// carries nothing but the URL.
@MainActor @Observable
final class CurrencyRates {
    struct Table: Codable, Equatable, Sendable {
        /// The day the bank published them, "2026-11-05".
        let date: String
        /// Units of each currency per euro; EUR itself is 1.
        let rates: [String: Double]
    }

    static let shared = CurrencyRates()
    private static let key = "currencyRateTable"
    private static let fetchedKey = "currencyRatesFetched"
    static let url = URL(string: "https://api.frankfurter.app/latest")!

    private(set) var table: Table?
    @ObservationIgnored private var fetching = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            table = try? JSONDecoder().decode(Table.self, from: data)
        }
    }

    func refreshIfNeeded() {
        let last = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date ?? .distantPast
        guard !fetching, table == nil || Date().timeIntervalSince(last) > 12 * 3600 else { return }
        fetching = true
        Task {
            defer { fetching = false }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            guard let (data, response) = try? await URLSession(configuration: config).data(from: Self.url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let table = Self.parse(data) else { return }
            self.table = table
            UserDefaults.standard.set(try? JSONEncoder().encode(table), forKey: Self.key)
            UserDefaults.standard.set(Date(), forKey: Self.fetchedKey)
        }
    }

    /// `{"amount":1.0,"base":"EUR","date":"2026-11-05","rates":{"USD":1.08,...}}`
    nonisolated static func parse(_ data: Data) -> Table? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = json["date"] as? String,
              let rates = json["rates"] as? [String: Any] else { return nil }
        var table = rates.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        table[(json["base"] as? String) ?? "EUR"] = 1
        return table.count > 1 ? Table(date: date, rates: table) : nil
    }
}
