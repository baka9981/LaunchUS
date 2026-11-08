import AppKit
import AVFoundation
import SwiftUI

// MARK: - Weather

/// The weather for 动态 › 城市天气, from Open-Meteo (free, no account): only the city's
/// coordinates are sent. Refreshed every half hour while it's the background.
@MainActor @Observable
final class WeatherService {
    static let shared = WeatherService()

    struct Now: Equatable {
        var temperature: Double
        var code: Int
        var isDay: Bool
        var wind: Double
        /// Minutes after midnight, local to the city.
        var sunrise: Double
        var sunset: Double
        /// The city's offset from UTC, so the sky follows its clock rather than the Mac's.
        var utcOffset: Int
        var fetched: Date
    }

    struct Place: Identifiable, Hashable {
        let name: String
        let detail: String
        let latitude: Double
        let longitude: Double
        var id: String { "\(latitude),\(longitude)" }
    }

    private(set) var now: Now?
    private(set) var failed = false
    @ObservationIgnored private var fetching: String?

    /// The city in use: the one picked in settings, else one near the Mac's time zone.
    var cityName: String {
        let s = Settings.shared
        return s.weatherCity.isEmpty ? Self.timeZoneCity : s.weatherCity
    }

    static var timeZoneCity: String {
        TimeZone.current.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
    }

    /// Fetches when there's nothing yet, it's stale, or the city changed.
    func refreshIfNeeded() {
        let s = Settings.shared
        let key = "\(s.weatherCity)|\(s.weatherLatitude)|\(s.weatherLongitude)"
        if let now, fetching == nil, key == lastKey, Date().timeIntervalSince(now.fetched) < 30 * 60 { return }
        guard fetching != key else { return }
        fetching = key
        Task {
            defer { if fetching == key { fetching = nil } }
            var lat = s.weatherLatitude, lon = s.weatherLongitude
            if s.weatherCity.isEmpty || (lat == 0 && lon == 0) {
                guard let place = await Self.search(Self.timeZoneCity).first else { failed = true; return }
                lat = place.latitude; lon = place.longitude
            }
            let fresh = await Self.fetch(latitude: lat, longitude: lon)
            // A newer city was picked meanwhile: its own fetch decides.
            guard fetching == key else { return }
            if let fresh {
                now = fresh
                failed = false
                lastKey = key
            } else {
                failed = now == nil
            }
        }
    }

    @ObservationIgnored private var lastKey = ""

    static func fetch(latitude: Double, longitude: Double) async -> Now? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? [String: Any] else { return nil }
        let daily = json["daily"] as? [String: Any]
        func minutes(_ key: String, _ fallback: Double) -> Double {
            // "2026-11-08T07:03"
            guard let text = (daily?[key] as? [String])?.first, let t = text.split(separator: "T").last else { return fallback }
            let hm = t.split(separator: ":").compactMap { Double($0) }
            return hm.count >= 2 ? hm[0] * 60 + hm[1] : fallback
        }
        return Now(temperature: current["temperature_2m"] as? Double ?? 0,
                   code: current["weather_code"] as? Int ?? 0,
                   isDay: (current["is_day"] as? Int ?? 1) == 1,
                   wind: current["wind_speed_10m"] as? Double ?? 0,
                   sunrise: minutes("sunrise", 390), sunset: minutes("sunset", 1125),
                   utcOffset: json["utc_offset_seconds"] as? Int ?? TimeZone.current.secondsFromGMT(),
                   fetched: Date())
    }

    /// Cities matching a name, in the app's language where Open-Meteo has it.
    static func search(_ name: String) async -> [Place] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        parts.queryItems = [URLQueryItem(name: "name", value: trimmed), URLQueryItem(name: "count", value: "8"),
                            URLQueryItem(name: "language", value: language)]
        guard let url = parts.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { r in
            guard let name = r["name"] as? String, let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { return nil }
            let detail = [r["admin1"] as? String, r["country"] as? String].compactMap { $0 }.joined(separator: ", ")
            return Place(name: name, detail: detail, latitude: lat, longitude: lon)
        }
    }
}

/// What the sky is doing, from a WMO weather code.
enum Condition: Equatable {
    case clear, partly, overcast, fog, drizzle, rain, snow, thunder

    init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1, 2: self = .partly
        case 3: self = .overcast
        case 45, 48: self = .fog
        case 51...57: self = .drizzle
        case 61...67, 80...82: self = .rain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .thunder
        default: self = .partly
        }
    }

    var title: String {
        switch self {
        case .clear: String(localized: "晴")
        case .partly: String(localized: "多云")
        case .overcast: String(localized: "阴")
        case .fog: String(localized: "雾")
        case .drizzle: String(localized: "小雨")
        case .rain: String(localized: "雨")
        case .snow: String(localized: "雪")
        case .thunder: String(localized: "雷雨")
        }
    }

    /// How much grey cloud covers the sky's colour.
    var overcast: Double {
        switch self {
        case .clear: 0
        case .partly: 0.15
        case .overcast: 0.55
        case .fog: 0.6
        case .drizzle: 0.5
        case .rain: 0.62
        case .snow: 0.5
        case .thunder: 0.75
        }
    }

    /// Puffs of cloud drifting across.
    var clouds: Int {
        switch self {
        case .clear: 0
        case .partly: 5
        case .fog: 3
        case .overcast, .drizzle, .snow: 9
        case .rain, .thunder: 11
        }
    }
}

// MARK: - Sky colours

/// The sky's colours at a time of day: night, dawn, day, dusk, as top and horizon colours.
enum SkyPalette {
    struct Stop {
        var minute: Double
        var top: SIMD3<Double>
        var bottom: SIMD3<Double>
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(Double(hex >> 16 & 0xFF), Double(hex >> 8 & 0xFF), Double(hex & 0xFF)) / 255
    }

    static let night = (rgb(0x070B1F), rgb(0x18223F))
    static let dawn = (rgb(0x2B3770), rgb(0xF4A27E))
    static let morning = (rgb(0x3D86D6), rgb(0xB5DBF7))
    static let noon = (rgb(0x2475D4), rgb(0x92C6F0))
    static let dusk = (rgb(0x33255A), rgb(0xF2794A))

    /// Colours at `minute` after midnight with the sun up from `sunrise` to `sunset`.
    static func colors(minute: Double, sunrise: Double, sunset: Double) -> (SIMD3<Double>, SIMD3<Double>) {
        let stops: [Stop] = [
            Stop(minute: 0, top: night.0, bottom: night.1),
            Stop(minute: sunrise - 75, top: night.0, bottom: night.1),
            Stop(minute: sunrise - 5, top: dawn.0, bottom: dawn.1),
            Stop(minute: sunrise + 60, top: morning.0, bottom: morning.1),
            Stop(minute: (sunrise + sunset) / 2, top: noon.0, bottom: noon.1),
            Stop(minute: sunset - 70, top: morning.0, bottom: morning.1),
            Stop(minute: sunset + 5, top: dusk.0, bottom: dusk.1),
            Stop(minute: sunset + 60, top: night.0, bottom: night.1),
            Stop(minute: 1440, top: night.0, bottom: night.1),
        ]
        let m = min(1440, max(0, minute))
        for (a, b) in zip(stops, stops.dropFirst()) where m >= a.minute && m <= b.minute {
            let span = max(1, b.minute - a.minute)
            let t = smooth((m - a.minute) / span)
            return (a.top + (b.top - a.top) * t, a.bottom + (b.bottom - a.bottom) * t)
        }
        return night
    }

    /// 0 at night, 1 in full daylight.
    static func daylight(minute: Double, sunrise: Double, sunset: Double) -> Double {
        if minute < sunrise - 40 || minute > sunset + 40 { return 0 }
        if minute < sunrise + 40 { return smooth((minute - sunrise + 40) / 80) }
        if minute > sunset - 40 { return smooth((sunset + 40 - minute) / 80) }
        return 1
    }

    static func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    static func color(_ v: SIMD3<Double>, opacity: Double = 1) -> Color {
        Color(red: v.x, green: v.y, blue: v.z, opacity: opacity)
    }
}

// MARK: - The view

/// 动态 background: the sky through the day, a city's weather, or a video.
struct DynamicBackground: View {
    let kind: DynamicWallpaper
    /// Only moves while the launcher is on screen.
    let animating: Bool
    let style: BackgroundStyle

    var body: some View {
        switch kind {
        case .live:
            if let url = LiveWallpaper.url(Settings.shared.liveWallpaper) {
                LiveVideoView(url: url, playing: animating, blur: style.blur, saturation: style.saturation)
            } else {
                SkyView(weather: false, animating: animating)
                    .saturation(style.saturation)
            }
        case .sky:
            SkyView(weather: false, animating: animating)
                .saturation(style.saturation)
        case .weather:
            SkyView(weather: true, animating: animating)
                .saturation(style.saturation)
                .onAppear { WeatherService.shared.refreshIfNeeded() }
                .onChange(of: animating) { _, on in if on { WeatherService.shared.refreshIfNeeded() } }
        }
    }
}

/// The sky drawn live: its colours for the time of day, sun or moon, stars, and for 城市天气
/// the clouds, rain, snow, fog and lightning of the city's weather now.
struct SkyView: View {
    let weather: Bool
    let animating: Bool

    /// Debug aids: LAUNCHUS_SKY_TIME=18:40 and LAUNCHUS_WEATHER_CODE=63 stand in for the clock and the weather.
    private static let debugMinute: Double? = ProcessInfo.processInfo.environment["LAUNCHUS_SKY_TIME"].flatMap { text in
        let hm = text.split(separator: ":").compactMap { Double($0) }
        return hm.count == 2 ? hm[0] * 60 + hm[1] : nil
    }
    static let debugCode: Int? = ProcessInfo.processInfo.environment["LAUNCHUS_WEATHER_CODE"].flatMap { Int($0) }

    var body: some View {
        let service = WeatherService.shared
        let now = weather ? service.now : nil
        let condition = weather ? Condition(code: Self.debugCode ?? now?.code ?? 0) : .clear
        let sunrise = now?.sunrise ?? 390, sunset = now?.sunset ?? 1125
        // Rain, snow and lightning need 30 fps; stars and drifting clouds look the same at 10.
        let fast = condition == .rain || condition == .drizzle || condition == .snow || condition == .thunder
        TimelineView(.animation(minimumInterval: fast ? 1.0 / 30 : 1.0 / 10, paused: !animating)) { context in
            let minute = Self.debugMinute ?? Self.minute(of: context.date, utcOffset: now?.utcOffset)
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { gc, size in
                draw(in: &gc, size: size, minute: minute, sunrise: sunrise, sunset: sunset, condition: condition,
                     wind: now?.wind ?? 8, time: t)
            }
        }
        .ignoresSafeArea()
    }

    private static func minute(of date: Date, utcOffset: Int?) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utcOffset.flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(c.hour ?? 0) * 60 + Double(c.minute ?? 0) + Double(c.second ?? 0) / 60
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, minute: Double, sunrise: Double, sunset: Double,
                      condition: Condition, wind: Double, time t: Double) {
        let rect = CGRect(origin: .zero, size: size)
        let daylight = SkyPalette.daylight(minute: minute, sunrise: sunrise, sunset: sunset)
        var (top, bottom) = SkyPalette.colors(minute: minute, sunrise: sunrise, sunset: sunset)
        // Cloud cover greys the sky: lighter by day, near black by night.
        let grey = condition == .snow ? SIMD3<Double>(0.72, 0.76, 0.81) : SIMD3<Double>(0.45, 0.5, 0.56)
        let cover = condition.overcast
        let shade = grey * (0.25 + 0.75 * daylight)
        top = top + (shade * 0.85 - top) * cover
        bottom = bottom + (shade - bottom) * cover
        gc.fill(Path(rect), with: .linearGradient(Gradient(colors: [SkyPalette.color(top), SkyPalette.color(bottom)]),
                                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

        // Stars, where the sky is clear enough to show them.
        let starAlpha = (1 - daylight) * (1 - cover * 1.3)
        if starAlpha > 0.02 {
            for i in 0..<160 {
                let x = Self.hash(i, 1) * size.width
                let y = Self.hash(i, 2) * size.height * 0.75
                let r = 0.6 + Self.hash(i, 3) * 1.3
                let twinkle = 0.55 + 0.45 * sin(t * (0.6 + Self.hash(i, 4) * 1.6) + Self.hash(i, 5) * 6.28)
                gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(starAlpha * twinkle * (0.4 + Self.hash(i, 6) * 0.6))))
            }
        }

        // The sun across the day, the moon across the night: a soft glow on an arc.
        let dayLength = max(60, sunset - sunrise)
        let sunProgress = (minute - sunrise) / dayLength
        let glowStrength = 1 - cover * 0.9
        if sunProgress > -0.08, sunProgress < 1.08, glowStrength > 0.05 {
            let p = Self.arc(sunProgress, size: size)
            let warmth = 1 - min(1, abs(sunProgress - 0.5) * 2.2)   // orange near the horizon
            let core = Color(red: 1, green: 0.85 + 0.12 * warmth, blue: 0.55 + 0.4 * warmth)
            let radius = size.width * 0.32
            gc.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(Gradient(colors: [core.opacity(0.55 * glowStrength), core.opacity(0)]),
                                          center: p, startRadius: 0, endRadius: radius))
            let disc = size.width * 0.018
            gc.fill(Path(ellipseIn: CGRect(x: p.x - disc, y: p.y - disc, width: disc * 2, height: disc * 2)),
                    with: .color(core.opacity(0.9 * glowStrength)))
        } else if daylight < 0.5, glowStrength > 0.05 {
            let night = (minute > sunset ? minute - sunset : minute + 1440 - sunset) / max(60, 1440 - dayLength)
            let p = Self.arc(night, size: size)
            let radius = size.width * 0.12
            gc.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                    with: .radialGradient(Gradient(colors: [Color.white.opacity(0.16 * glowStrength), .clear]),
                                          center: p, startRadius: 0, endRadius: radius))
            let disc = size.width * 0.013
            gc.fill(Path(ellipseIn: CGRect(x: p.x - disc, y: p.y - disc, width: disc * 2, height: disc * 2)),
                    with: .color(Color(red: 0.95, green: 0.95, blue: 0.88).opacity(0.85 * glowStrength)))
        }

        // Clouds: soft puffs drifting with the wind. Even a clear 天色 sky gets a couple.
        let clouds = weather ? condition.clouds : 3
        if clouds > 0 {
            let lit = 0.35 + 0.65 * daylight
            let puffColor = condition == .thunder || condition == .rain
                ? Color(white: 0.55 * lit + 0.1) : Color(white: 0.92 * lit + 0.08)
            let speed = 4 + wind * 0.8
            for i in 0..<clouds {
                let w = size.width * (0.22 + Self.hash(i, 11) * 0.3)
                let span = size.width + w * 2
                let x = (Self.hash(i, 12) * span + t * speed * (0.6 + Self.hash(i, 13) * 0.8)).truncatingRemainder(dividingBy: span) - w
                let y = size.height * (0.06 + Self.hash(i, 14) * (weather ? 0.5 : 0.35))
                let alpha = (weather ? 0.22 + cover * 0.35 : 0.14) * (0.6 + Self.hash(i, 15) * 0.4)
                for j in 0..<5 {
                    let px = x + (Double(j) / 4 - 0.5) * w * 0.8 + Self.hash(i * 7 + j, 16) * w * 0.15
                    let py = y + (Self.hash(i * 7 + j, 17) - 0.5) * w * 0.12
                    let r = w * (0.22 + Self.hash(i * 7 + j, 18) * 0.16)
                    gc.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r * 0.62, width: r * 2, height: r * 1.24)),
                            with: .radialGradient(Gradient(colors: [puffColor.opacity(alpha), puffColor.opacity(0)]),
                                                  center: CGPoint(x: px, y: py), startRadius: 0, endRadius: r))
                }
            }
        }

        guard weather else { return }

        // Fog: pale bands near the ground.
        if condition == .fog {
            for i in 0..<4 {
                let y = size.height * (0.45 + Double(i) * 0.14)
                let drift = sin(t * 0.05 + Double(i)) * size.width * 0.05
                let band = CGRect(x: -size.width * 0.1 + drift, y: y - size.height * 0.12, width: size.width * 1.2, height: size.height * 0.24)
                gc.fill(Path(ellipseIn: band), with: .radialGradient(
                    Gradient(colors: [Color(white: 0.85).opacity(0.22), .clear]),
                    center: CGPoint(x: band.midX, y: band.midY), startRadius: 0, endRadius: band.width / 2))
            }
        }

        // Rain: slanted streaks falling fast; drizzle fewer and finer.
        if condition == .rain || condition == .drizzle || condition == .thunder {
            let count = condition == .drizzle ? 140 : 320
            let slant = min(0.35, wind / 80)
            var streaks = Path()
            for i in 0..<count {
                let speed = size.height * (1.1 + Self.hash(i, 21) * 0.6)
                let length = (condition == .drizzle ? 10 : 18) + Self.hash(i, 22) * 16
                let span = size.height + length
                let y = (Self.hash(i, 23) * span + t * speed).truncatingRemainder(dividingBy: span) - length
                let x = (Self.hash(i, 24) * (size.width + 200) + y * slant).truncatingRemainder(dividingBy: size.width + 200) - 100
                streaks.move(to: CGPoint(x: x, y: y))
                streaks.addLine(to: CGPoint(x: x + length * slant, y: y + length))
            }
            gc.stroke(streaks, with: .color(.white.opacity(condition == .drizzle ? 0.22 : 0.3)), lineWidth: 1)
        }

        // Snow: flakes drifting down and swaying.
        if condition == .snow {
            for i in 0..<220 {
                let speed = 22 + Self.hash(i, 31) * 40
                let r = 1 + Self.hash(i, 32) * 2.6
                let span = size.height + 10
                let y = (Self.hash(i, 33) * span + t * speed).truncatingRemainder(dividingBy: span) - 5
                let sway = sin(t * (0.4 + Self.hash(i, 34)) + Self.hash(i, 35) * 6.28) * 18
                let x = (Self.hash(i, 36) * size.width + sway + t * wind * 0.3).truncatingRemainder(dividingBy: size.width)
                gc.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(0.5 + Self.hash(i, 37) * 0.4)))
            }
        }

        // Lightning: now and then the sky flashes.
        if condition == .thunder {
            let cycle = 9.0
            let phase = t.truncatingRemainder(dividingBy: cycle)
            let flash = phase < 0.12 ? 1 - phase / 0.12 : (phase > 0.25 && phase < 0.33 ? 0.6 : 0)
            if flash > 0 {
                gc.fill(Path(rect), with: .color(.white.opacity(0.28 * flash)))
            }
        }
    }

    /// A point on the sun's (or moon's) path: rising on the left, highest in the middle.
    private static func arc(_ progress: Double, size: CGSize) -> CGPoint {
        let p = min(1.1, max(-0.1, progress))
        return CGPoint(x: size.width * (0.08 + 0.84 * p),
                       y: size.height * (0.78 - 0.62 * sin(.pi * min(1, max(0, p)))))
    }

    /// A fixed pseudo-random 0…1 for particle `i`, so particles need no stored state.
    private static func hash(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: i &* 374761393 &+ salt &* 668265263)
        x = (x ^ (x >> 13)) &* 1274126177
        x ^= x >> 16
        return Double(x & 0xFFFFFF) / Double(0xFFFFFF)
    }
}

/// "吉隆坡  28°  多云", small in the top corner, over the background's darkening.
struct WeatherLabel: View {
    var body: some View {
        let service = WeatherService.shared
        let now = service.now
        let condition = Condition(code: SkyView.debugCode ?? now?.code ?? 0)
        let city = service.cityName
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: city).font(.system(size: 15, weight: .medium))
            if let now {
                Text(verbatim: "\(Int(now.temperature.rounded()))°").font(.system(size: 26, weight: .light))
                Text(verbatim: condition.title).font(.system(size: 15))
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
        .allowsHitTesting(false)
    }
}

// MARK: - Video

/// A video chosen as the background, copied into LaunchUS's own data.
enum LiveWallpaper {
    static var directory: URL { LayoutStore.directory.appendingPathComponent("LiveWallpaper", isDirectory: true) }

    static func url(_ name: String) -> URL? {
        guard !name.isEmpty else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies the video in and removes ones no profile uses any more; returns the stored name.
    static func importVideo(_ source: URL, keeping inUse: Set<String>) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())
        try fm.copyItem(at: source, to: directory.appendingPathComponent(name))
        for old in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where old != name && !inUse.contains(old) {
            try? fm.removeItem(at: directory.appendingPathComponent(old))
        }
        return name
    }
}

/// The video, filling the screen, looping without sound; blurred and toned like a picture.
private struct LiveVideoView: NSViewRepresentable {
    let url: URL
    let playing: Bool
    let blur: Double
    let saturation: Double

    func makeNSView(context: Context) -> VideoLayerView { VideoLayerView() }

    func updateNSView(_ view: VideoLayerView, context: Context) {
        view.show(url)
        view.setPlaying(playing)
        view.setLook(blur: blur, saturation: saturation)
    }

    final class VideoLayerView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var current: URL?
        private let playerLayer = AVPlayerLayer()
        private var look: (Double, Double)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerUsesCoreImageFilters = true
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A little larger than the view, so a blur's soft edge falls outside it.
            let margin = CGFloat(look?.0 ?? 0) * 0.6
            playerLayer.frame = bounds.insetBy(dx: -margin, dy: -margin)
            CATransaction.commit()
        }

        func show(_ url: URL) {
            guard url != current else { return }
            current = url
            looper = nil
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        func setPlaying(_ on: Bool) {
            if on { player.play() } else { player.pause() }
        }

        func setLook(blur: Double, saturation: Double) {
            // Video is drawn at screen size: a lighter blur than the picture's reads the same.
            let radius = blur * 0.35
            guard look.map({ $0 != (radius, saturation) }) ?? true else { return }
            look = (radius, saturation)
            var filters: [CIFilter] = []
            if radius > 0.5, let f = CIFilter(name: "CIGaussianBlur") {
                f.setValue(radius, forKey: kCIInputRadiusKey)
                filters.append(f)
            }
            if abs(saturation - 1) > 0.01, let f = CIFilter(name: "CIColorControls") {
                f.setValue(saturation, forKey: kCIInputSaturationKey)
                filters.append(f)
            }
            playerLayer.filters = filters.isEmpty ? nil : filters
            needsLayout = true
        }
    }
}
