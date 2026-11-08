import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 背景 › 动态: which one, and its city or video.
struct DynamicWallpaperRows: View {
    let model: LauncherModel
    @Bindable var settings: Settings
    @State private var pickingCity = false

    var body: some View {
        Row(title: String(localized: "动态"),
            info: String(localized: "天色：天空随时间变化，黎明、白天、黄昏和夜晚。城市天气：按城市当前的天气下雨、下雪、起雾或打雷。视频：用你自己的视频，静音循环播放")) {
            Picker("", selection: $settings.dynamicWallpaper) {
                ForEach(DynamicWallpaper.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        switch settings.dynamicWallpaper {
        case .sky:
            EmptyView()
        case .weather:
            Row(title: String(localized: "城市"), subtitle: citySubtitle) {
                HStack(spacing: 8) {
                    Toggle(String(localized: "显示天气"), isOn: $settings.showWeatherLabel).toggleStyle(.checkbox)
                    Button(String(localized: "更改…")) { pickingCity = true }
                        .popover(isPresented: $pickingCity, arrowEdge: .bottom) {
                            CityPicker(settings: settings) { pickingCity = false }
                        }
                }
            }
            .onAppear { WeatherService.shared.refreshIfNeeded() }
        case .live:
            Row(title: String(localized: "视频"),
                subtitle: LiveWallpaper.url(settings.liveWallpaper) == nil
                    ? String(localized: "还没有选择，暂时显示天色") : nil,
                info: String(localized: "MP4 或 MOV，静音循环播放，只在启动台打开时播放。视频会复制到 LaunchUS 的数据文件夹")) {
                Button(String(localized: "选择视频…"), action: chooseVideo)
            }
        }
    }

    private var citySubtitle: String {
        let service = WeatherService.shared
        var parts = [settings.weatherCity.isEmpty
            ? String(localized: "\(WeatherService.timeZoneCity)（按时区）") : settings.weatherCity]
        if let now = service.now {
            parts.append("\(Int(now.temperature.rounded()))° \(Condition(code: now.code).title)")
        } else if service.failed {
            parts.append(String(localized: "暂时获取不到天气"))
        }
        return parts.joined(separator: " · ")
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = String(localized: "选择一段视频作为动态背景")
        guard Modal.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        // Other profiles may show a video of their own; those stay.
        let inUse = Set(model.profileNames.filter { $0 != model.currentProfile }
            .compactMap { model.profileSetting("liveWallpaper", of: $0, current: "") })
        do {
            settings.liveWallpaper = try LiveWallpaper.importVideo(url, keeping: inUse)
        } catch {
            NSLog("LaunchUS: failed to copy the video: \(error)")
        }
    }
}

/// Search a city by name; picking one sets 城市天气 to it.
private struct CityPicker: View {
    @Bindable var settings: Settings
    let done: () -> Void
    @State private var query = ""
    @State private var results: [WeatherService.Place] = []
    @State private var searching = false
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField(String(localized: "城市名，例如 上海、Tokyo"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button(String(localized: "搜索"), action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if searching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if searched && results.isEmpty {
                Text("没有找到这个城市").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { place in
                        Button { pick(place) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: place.name).font(.system(size: 13))
                                Text(verbatim: place.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                if !settings.weatherCity.isEmpty {
                    Button(String(localized: "按时区自动")) {
                        settings.weatherCity = ""
                        settings.weatherLatitude = 0
                        settings.weatherLongitude = 0
                        WeatherService.shared.refreshIfNeeded()
                        done()
                    }
                }
                Spacer()
                Text("天气来自 Open-Meteo").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func search() {
        searching = true
        Task {
            results = await WeatherService.search(query)
            searching = false
            searched = true
        }
    }

    private func pick(_ place: WeatherService.Place) {
        settings.weatherCity = place.name
        settings.weatherLatitude = place.latitude
        settings.weatherLongitude = place.longitude
        WeatherService.shared.refreshIfNeeded()
        done()
    }
}
