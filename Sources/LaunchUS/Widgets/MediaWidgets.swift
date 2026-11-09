import AppKit
import AVFoundation
import SwiftUI

// Widgets that play something: the song in Music or Spotify, generated white noise, and a
// looping video of your own.

// MARK: - Now playing

/// The song in Music or Spotify. Both post a notification on every change, so nothing is
/// polled; controls and cover art go through Apple events.
@MainActor @Observable
final class NowPlaying {
    static let shared = NowPlaying()

    enum Player: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"

        var scriptName: String { self == .music ? "Music" : "Spotify" }
        var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    }

    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    private(set) var player: Player?
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var album = ""
    private(set) var playing = false
    private(set) var artwork: NSImage?
    @ObservationIgnored private var artworkFor = ""
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var asked = false
    private static let queue = DispatchQueue(label: "launchus.nowplaying")

    private init() {
        let center = DistributedNotificationCenter.default()
        for (name, player) in [("com.apple.Music.playerInfo", Player.music), ("com.spotify.client.PlaybackStateChanged", .spotify)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                MainActor.assumeIsolated {
                    self?.update(player: player,
                                 state: info["Player State"] as? String ?? "",
                                 title: info["Name"] as? String,
                                 artist: info["Artist"] as? String,
                                 album: info["Album"] as? String)
                }
            })
        }
    }

    /// Asks a running player what it's playing, once, for a widget that appears before any
    /// notification came. A player that isn't open stays closed.
    func refresh() {
        guard !asked else { return }
        guard let running = Player.allCases.first(where: \.isRunning) else { return }
        asked = true
        let script = """
        tell application "\(running.scriptName)"
            if player state is stopped then return "Stopped"
            set t to current track
            return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t)
        end tell
        """
        Self.run(script) { [weak self] descriptor in
            guard let lines = descriptor?.stringValue?.components(separatedBy: "\n") else { return }
            let state = lines.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""
            self?.update(player: running, state: state,
                         title: lines.count > 1 ? lines[1] : nil,
                         artist: lines.count > 2 ? lines[2] : nil,
                         album: lines.count > 3 ? lines[3] : nil)
        }
    }

    private func update(player: Player, state: String, title: String?, artist: String?, album: String?) {
        // A player stopping doesn't take over from one that's still playing.
        if state == "Stopped", self.player != player, self.player != nil { return }
        self.player = player
        playing = state == "Playing"
        if state == "Stopped" {
            self.title = ""
            self.artist = ""
            self.album = ""
            artwork = nil
            artworkFor = ""
            return
        }
        if let title { self.title = title }
        if let artist { self.artist = artist }
        if let album { self.album = album }
        let key = "\(player.rawValue)|\(self.title)|\(self.album)"
        if key != artworkFor {
            artworkFor = key
            loadArtwork(player, key: key)
        }
    }

    /// A button was pressed with no player open: the widget says so for a moment, rather
    /// than opening Music.
    private(set) var noPlayer = false
    @ObservationIgnored private var noPlayerWork: DispatchWorkItem?

    func perform(_ command: Command) {
        guard let target = player.flatMap({ $0.isRunning ? $0 : nil }) ?? Player.allCases.first(where: \.isRunning) else {
            noPlayer = true
            noPlayerWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.noPlayer = false }
            noPlayerWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            return
        }
        if player == nil { player = target }
        // Show the change at once; the player's notification confirms it.
        if command == .playPause, !title.isEmpty { playing.toggle() }
        Self.run("tell application \"\(target.scriptName)\" to \(command.rawValue)") { [weak self] _ in
            self?.asked = false
            if self?.title.isEmpty == true { self?.refresh() }
        }
    }

    private func loadArtwork(_ player: Player, key: String) {
        artwork = nil
        let script = player == .music
            ? "tell application \"Music\" to if exists artwork 1 of current track then get data of artwork 1 of current track"
            : "tell application \"Spotify\" to artwork url of current track"
        Self.run(script) { [weak self] descriptor in
            guard let self, artworkFor == key, let descriptor else { return }
            if player == .music {
                artwork = NSImage(data: descriptor.data)
            } else if let text = descriptor.stringValue, let url = URL(string: text), url.scheme == "https" {
                Task {
                    guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                    if self.artworkFor == key { self.artwork = NSImage(data: data) }
                }
            }
        }
    }

    private static func run(_ source: String, done: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            nonisolated(unsafe) let descriptor = error == nil ? result : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { done(descriptor) } }
        }
    }
}

struct MusicWidget: View {
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize
    let live: Bool

    enum Hit: Equatable { case command(NowPlaying.Command), open }

    /// The three buttons and the cover, in content coordinates.
    static func layout(_ size: WidgetItem.Size, card: CGSize) -> (cover: CGRect, text: CGRect, buttons: [CGRect]) {
        let area = ToolGrid.content(card).size
        let button = area.height * (size == .large ? 0.13 : size == .medium ? 0.3 : 0.26)
        switch size {
        case .small:
            let cover = CGRect(x: 0, y: 0, width: area.width * 0.42, height: area.width * 0.42)
            let row = CGRect(x: 0, y: area.height - button, width: area.width, height: button)
            return (cover, CGRect(x: 0, y: cover.maxY, width: area.width, height: row.minY - cover.maxY), buttons(in: row, side: button))
        case .medium:
            let cover = CGRect(x: 0, y: 0, width: area.height, height: area.height)
            let right = CGRect(x: cover.maxX + area.width * 0.05, y: 0, width: area.width - cover.width - area.width * 0.05, height: area.height)
            let row = CGRect(x: right.minX, y: area.height - button, width: right.width, height: button)
            return (cover, CGRect(x: right.minX, y: 0, width: right.width, height: row.minY), buttons(in: row, side: button))
        case .large:
            let side = area.height * 0.6
            let cover = CGRect(x: (area.width - side) / 2, y: 0, width: side, height: side)
            let row = CGRect(x: 0, y: area.height - button, width: area.width, height: button)
            return (cover, CGRect(x: 0, y: cover.maxY, width: area.width, height: row.minY - cover.maxY), buttons(in: row, side: button))
        }
    }

    private static func buttons(in row: CGRect, side: CGFloat) -> [CGRect] {
        let gap = min(side * 0.6, (row.width - side * 3) / 2)
        let total = side * 3 + gap * 2
        return (0..<3).map { i in
            CGRect(x: row.midX - total / 2 + CGFloat(i) * (side + gap), y: row.minY, width: side, height: side)
        }
    }

    static func hit(_ point: CGPoint, size: WidgetItem.Size, card: CGSize) -> Hit {
        let local = ToolGrid.local(point, card: card)
        let commands: [NowPlaying.Command] = [.previous, .playPause, .next]
        for (rect, command) in zip(layout(size, card: card).buttons, commands) where rect.insetBy(dx: -6, dy: -6).contains(local) {
            return .command(command)
        }
        return .open
    }

    var body: some View {
        let now = NowPlaying.shared
        let (cover, text, buttons) = Self.layout(size, card: card)
        let area = ToolGrid.content(card).size
        ZStack(alignment: .topLeading) {
            artwork(now, side: cover.width)
                .offset(x: cover.minX, y: cover.minY)
            VStack(alignment: size == .large ? .center : .leading, spacing: unit * 0.02) {
                if size != .small { Spacer(minLength: 0) }
                Text(now.title.isEmpty
                     ? now.noPlayer ? String(localized: "先打开“音乐”或 Spotify") : String(localized: "没有在播放")
                     : now.title)
                    .font(.system(size: unit * (size == .large ? 0.16 : 0.13), weight: .semibold)).lineLimit(size == .medium ? 2 : 1)
                if !now.artist.isEmpty {
                    Text(now.artist).font(.system(size: unit * 0.1)).opacity(0.65).lineLimit(1)
                }
                if size != .small { Spacer(minLength: 0) }
            }
            .frame(width: text.width, height: text.height, alignment: size == .large ? .center : size == .small ? .bottomLeading : .leading)
            .offset(x: text.minX, y: text.minY)
            ForEach(Array(zip(["backward.fill", now.playing ? "pause.fill" : "play.fill", "forward.fill"], buttons).enumerated()), id: \.offset) { i, pair in
                let (symbol, rect) = pair
                ZStack {
                    if i == 1 { Circle().fill(.primary.opacity(0.15)) }
                    Image(systemName: symbol).font(.system(size: rect.height * (i == 1 ? 0.45 : 0.4), weight: .semibold))
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .onAppear { now.refresh() }
        .task(id: live) { if live { now.refresh() } }
    }

    private func artwork(_ now: NowPlaying, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.14, style: .continuous)
        return Group {
            if let image = now.artwork {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.5), Color(red: 0.92, green: 0.18, blue: 0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note").font(.system(size: side * 0.4, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

// MARK: - White noise

/// Noise made on the fly, so there's nothing to download and it never loops audibly.
@MainActor @Observable
final class NoisePlayer {
    static let shared = NoisePlayer()

    enum Sound: String, CaseIterable {
        case white, pink, brown, rain, ocean

        var title: String {
            switch self {
            case .white: String(localized: "白噪音")
            case .pink: String(localized: "粉红噪音")
            case .brown: String(localized: "棕噪音")
            case .rain: String(localized: "雨声")
            case .ocean: String(localized: "海浪")
            }
        }

        var symbol: String {
            switch self {
            case .white: "waveform"
            case .pink: "waveform.path"
            case .brown: "wind"
            case .rain: "cloud.rain"
            case .ocean: "water.waves"
            }
        }
    }

    private(set) var playing: Sound?
    /// When the sleep timer stops it.
    private(set) var stopAt: Date?
    var volume: Double = UserDefaults.app.object(forKey: "noiseVolume") as? Double ?? 0.5 {
        didSet {
            UserDefaults.app.set(volume, forKey: "noiseVolume")
            engine?.mainMixerNode.outputVolume = Float(volume)
        }
    }
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let generator = NoiseGenerator()
    @ObservationIgnored private var stopWork: DispatchWorkItem?
    @ObservationIgnored private var timerWork: DispatchWorkItem?
    @ObservationIgnored private var configObserver: NSObjectProtocol?

    func toggle(_ sound: Sound) {
        if playing == sound { stop() } else { play(sound) }
    }

    func play(_ sound: Sound) {
        stopWork?.cancel()
        generator.set(sound: sound, on: true)
        if engine == nil {
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let generator = self.generator
            let node = AVAudioSourceNode(format: format) { _, _, frames, list in
                generator.render(frames: Int(frames), into: UnsafeMutableAudioBufferListPointer(list))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = Float(volume)
            self.engine = engine
            // AirPods coming or going stops the engine; build it again for the new output.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.outputChanged() }
            }
        }
        do {
            if engine?.isRunning != true { try engine?.start() }
            playing = sound
        } catch {
            NSLog("LaunchUS: white noise didn't start: \(error)")
            engine = nil
            playing = nil
        }
    }

    private func outputChanged() {
        configObserver.map(NotificationCenter.default.removeObserver)
        configObserver = nil
        engine?.stop()
        engine = nil
        guard let sound = playing else { return }
        playing = nil
        play(sound)
    }

    func stop() {
        guard playing != nil else { return }
        playing = nil
        setTimer(nil)
        generator.set(sound: nil, on: false)
        // Let it fade before the engine stops, so it doesn't click.
        let work = DispatchWorkItem { [weak self] in
            guard let self, playing == nil else { return }
            engine?.stop()
            engine = nil
            configObserver.map(NotificationCenter.default.removeObserver)
            configObserver = nil
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Stops after this many minutes; nil plays until stopped.
    func setTimer(_ minutes: Int?) {
        timerWork?.cancel()
        timerWork = nil
        guard let minutes else {
            stopAt = nil
            return
        }
        stopAt = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        timerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes * 60), execute: work)
    }
}

/// The audio thread's half: filters and a fade, nothing that allocates or locks.
private final class NoiseGenerator: @unchecked Sendable {
    // Written on the main thread, read on the audio thread; a torn read only changes the
    // sound for one buffer.
    private var kind = 0
    /// The sound asked for; the old one fades out before it comes in.
    private var next = 0
    private var target: Float = 0
    private var gain: Float = 0
    private var seed: UInt32 = 0x9E37_79B9
    private var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    private var brown: Float = 0
    private var drop: Float = 0
    private var dropTone: Float = 0
    private var time: Double = 0

    func set(sound: NoisePlayer.Sound?, on: Bool) {
        if let sound {
            let index = NoisePlayer.Sound.allCases.firstIndex(of: sound) ?? 0
            // Nothing playing yet: start on the new sound straight away.
            if gain < 0.01 { kind = index }
            next = index
        }
        target = on ? 1 : 0
    }

    private func white() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed) / Float(UInt32.max) * 2 - 1
    }

    /// Paul Kellet's filter: white noise with each octave 3 dB quieter.
    private func pink(_ w: Float) -> Float {
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        let out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        return out * 0.11
    }

    func render(frames: Int, into buffers: UnsafeMutableAudioBufferListPointer) {
        var kind = self.kind
        let next = self.next, target = self.target
        for frame in 0..<frames {
            if kind != next {
                // About a fifth of a second down, then the new sound fades up as usual.
                gain += (0 - gain) * 0.0006
                if gain < 0.004 { kind = next; self.kind = next }
            } else {
                gain += (target - gain) * 0.0002
            }
            let w = white()
            var sample: Float
            switch kind {
            case 0:
                sample = w * 0.35
            case 1:
                sample = pink(w)
            case 2:
                brown = (brown + 0.02 * w) / 1.02
                sample = brown * 3.2
            case 3:
                // Soft pink hiss with drops landing at random.
                if Float(seed & 0xFFFF) / 65535 < 0.0009 { drop = 0.6 + 0.4 * abs(white()); dropTone = 0 }
                drop *= 0.9965
                dropTone = dropTone * 0.6 + white() * 0.4
                sample = pink(w) * 0.55 + dropTone * drop * 0.35
            default:
                // Brown noise that swells and draws back about every nine seconds.
                brown = (brown + 0.02 * w) / 1.02
                let phase = Float((time.truncatingRemainder(dividingBy: 9)) / 9)
                let swell = 0.25 + 0.75 * pow(0.5 - 0.5 * cos(2 * .pi * phase), 1.6)
                sample = (brown * 3 + pink(white()) * 0.25) * swell
                time += 1.0 / 44100
            }
            sample *= gain
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
            }
        }
    }
}

struct NoiseWidget: View {
    let id: String
    let size: WidgetItem.Size
    let unit: CGFloat
    let card: CGSize
    let live: Bool

    enum Hit: Equatable { case toggle, sound(NoisePlayer.Sound) }

    static func sound(_ id: String) -> NoisePlayer.Sound {
        WidgetStore.shared.extras(id).noise.flatMap(NoisePlayer.Sound.init(rawValue:)) ?? .white
    }

    /// The play button and, on bigger cards, a button for each sound.
    static func layout(_ size: WidgetItem.Size, card: CGSize) -> (play: CGRect, sounds: [CGRect]) {
        let area = ToolGrid.content(card).size
        let gap = min(card.width, card.height) * 0.03
        switch size {
        case .small:
            let side = min(area.width, area.height) * 0.56
            return (CGRect(x: (area.width - side) / 2, y: area.height * 0.08, width: side, height: side), [])
        case .medium:
            let side = area.height * 0.7
            let play = CGRect(x: 0, y: 0, width: side, height: side)
            let left = side + area.width * 0.06
            let grid = ToolGrid.cells(count: 6, columns: 3, rows: 2, in: CGSize(width: area.width - left, height: area.height), gap: gap)
            return (play, grid.prefix(NoisePlayer.Sound.allCases.count).map { $0.offsetBy(dx: left, dy: 0) })
        case .large:
            let side = area.height * 0.36
            let play = CGRect(x: (area.width - side) / 2, y: area.height * 0.02, width: side, height: side)
            let top = side + area.height * 0.16
            let grid = ToolGrid.cells(count: 6, columns: 2, rows: 3, in: CGSize(width: area.width, height: area.height - top), gap: gap)
            return (play, grid.prefix(NoisePlayer.Sound.allCases.count).map { $0.offsetBy(dx: 0, dy: top) })
        }
    }

    static func hit(_ point: CGPoint, size: WidgetItem.Size, card: CGSize) -> Hit {
        let local = ToolGrid.local(point, card: card)
        let (_, sounds) = layout(size, card: card)
        for (rect, sound) in zip(sounds, NoisePlayer.Sound.allCases) where rect.contains(local) { return .sound(sound) }
        return .toggle
    }

    var body: some View {
        let player = NoisePlayer.shared
        let chosen = Self.sound(id)
        let on = player.playing == chosen
        let (play, sounds) = Self.layout(size, card: card)
        let area = ToolGrid.content(card).size
        ZStack(alignment: .topLeading) {
            ZStack {
                Circle().fill(on ? AnyShapeStyle(Color(red: 0.25, green: 0.6, blue: 0.75)) : AnyShapeStyle(.primary.opacity(0.12)))
                if on, live {
                    // Only this small canvas redraws; the card around it isn't laid out again.
                    TimelineView(.animation(minimumInterval: 1 / 12)) { context in
                        Canvas { gc, size in Self.drawBars(in: &gc, size: size, date: context.date) }
                    }
                    .frame(width: play.width * 0.6, height: play.height * 0.5)
                    .allowsHitTesting(false)
                } else {
                    Image(systemName: on ? "pause.fill" : chosen.symbol).font(.system(size: play.width * 0.36, weight: .semibold))
                }
            }
            .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: play.width, height: play.height)
            .offset(x: play.minX, y: play.minY)
            if size == .small {
                VStack(spacing: unit * 0.02) {
                    Text(chosen.title).font(.system(size: unit * 0.13, weight: .semibold))
                    if let stopAt = player.stopAt, on {
                        Text(stopAt, style: .timer).font(.system(size: unit * 0.09)).monospacedDigit().opacity(0.6)
                    }
                }
                .frame(width: area.width)
                .offset(y: play.maxY + unit * 0.06)
            } else {
                if size == .large {
                    Text(on ? chosen.title : String(localized: "点一下开始"))
                        .font(.system(size: unit * 0.13, weight: .semibold)).frame(width: area.width)
                        .offset(y: play.maxY + unit * 0.05)
                }
                ForEach(Array(zip(NoisePlayer.Sound.allCases, sounds)), id: \.0) { sound, rect in
                    let current = sound == chosen
                    RoundedRectangle(cornerRadius: min(rect.width, rect.height) * 0.3, style: .continuous)
                        .fill(current ? AnyShapeStyle(.primary.opacity(0.22)) : AnyShapeStyle(.primary.opacity(0.08)))
                        .overlay {
                            HStack(spacing: unit * 0.04) {
                                Image(systemName: sound.symbol).font(.system(size: unit * 0.1, weight: .semibold))
                                Text(sound.title).font(.system(size: unit * 0.09, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
                            }
                            .padding(.horizontal, unit * 0.04)
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
    }

    /// Five bars bouncing at their own pace, drawn straight into the canvas.
    private static func drawBars(in gc: inout GraphicsContext, size: CGSize, date: Date) {
        let t = date.timeIntervalSinceReferenceDate
        let width = size.width / 9
        for i in 0..<5 {
            let h = size.height * (0.3 + 0.7 * abs(sin(t * (2.1 + Double(i) * 0.7) + Double(i))))
            let rect = CGRect(x: CGFloat(i) * width * 2, y: (size.height - h) / 2, width: width, height: h)
            gc.fill(Capsule().path(in: rect), with: .foreground)
        }
    }
}

// MARK: - Video

struct VideoWidget: View {
    let id: String
    let unit: CGFloat
    let card: CGSize
    let live: Bool

    /// The chosen file: found again by its bookmark if it was moved.
    @MainActor static func url(_ id: String) -> URL? {
        let extras = WidgetStore.shared.extras(id)
        // Resolving the bookmark touches the disk, so a widget redrawing reuses the answer for a few seconds.
        let key = [extras.videoBookmark?.hashValue.description ?? "", extras.videoPath ?? ""].joined(separator: "|")
        if let hit = resolved[id], hit.key == key, hit.at.timeIntervalSinceNow > -5 { return hit.url }
        let url = resolve(extras)
        resolved[id] = (key, url, Date())
        return url
    }

    @MainActor private static var resolved: [String: (key: String, url: URL?, at: Date)] = [:]

    @MainActor private static func resolve(_ extras: WidgetStore.Extras) -> URL? {
        if let data = extras.videoBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return extras.videoPath.map(URL.init(fileURLWithPath:)).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    var body: some View {
        let extras = WidgetStore.shared.extras(id)
        if let url = Self.url(id) {
            LoopingVideo(url: url, sound: extras.videoSound == true, fit: extras.videoFit == true,
                         playing: live && !VideoPauses.shared.paused.contains(id))
                .frame(width: card.width, height: card.height)
                .overlay {
                    if VideoPauses.shared.paused.contains(id) {
                        Image(systemName: "play.fill").font(.system(size: unit * 0.3)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 4)
                    }
                }
        } else {
            ZStack {
                LinearGradient(colors: [Color(red: 0.5, green: 0.55, blue: 0.95), Color(red: 0.95, green: 0.4, blue: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(0.55)
                VStack(spacing: unit * 0.06) {
                    Image(systemName: "play.rectangle").font(.system(size: unit * 0.3))
                    if !id.hasPrefix("preview-") {
                        Text(extras.videoPath == nil ? String(localized: "点一下选择视频") : String(localized: "找不到视频，点一下重新选择"))
                            .font(.system(size: unit * 0.11, weight: .medium)).multilineTextAlignment(.center)
                    }
                }
                .opacity(0.85)
                .padding(unit * 0.1)
            }
            .frame(width: card.width, height: card.height)
        }
    }
}

/// Video widgets paused with a click; they play again when the launcher next opens.
@MainActor @Observable
final class VideoPauses {
    static let shared = VideoPauses()
    var paused: Set<String> = []
}

/// A muted (or not) video that loops forever, filling or fitting the card.
private struct LoopingVideo: NSViewRepresentable {
    let url: URL
    let sound: Bool
    let fit: Bool
    let playing: Bool

    func makeNSView(context: Context) -> VideoView { VideoView() }

    func updateNSView(_ view: VideoView, context: Context) {
        view.load(url)
        view.player.isMuted = !sound
        view.playerLayer.videoGravity = fit ? .resizeAspect : .resizeAspectFill
        if playing { view.player.play() } else { view.player.pause() }
    }

    static func dismantleNSView(_ view: VideoView, coordinator: ()) {
        view.player.pause()
        view.player.removeAllItems()
    }

    final class VideoView: NSView {
        let player = AVQueuePlayer()
        let playerLayer = AVPlayerLayer()
        private var looper: AVPlayerLooper?
        private var loaded: URL?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        func load(_ url: URL) {
            guard url != loaded else { return }
            loaded = url
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        // Clicks belong to the widget, not the video.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension LauncherModel {
    func chooseVideo(for id: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = String(localized: "选择一段视频放在小组件里")
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        WidgetStore.shared.updateExtras(id) { extras in
            extras.videoPath = url.path
            extras.videoBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }

    /// Without a video a click asks for one; with one it pauses or plays.
    func activateVideoWidget(_ widget: WidgetItem) {
        guard VideoWidget.url(widget.id) != nil else {
            chooseVideo(for: widget.id)
            return
        }
        if VideoPauses.shared.paused.remove(widget.id) == nil { VideoPauses.shared.paused.insert(widget.id) }
    }
}
