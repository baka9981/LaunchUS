import AppKit
import SwiftUI
import WebKit

/// A plugin widget: its HTML page in a web view that takes no clicks, so the card under it
/// still opens, drags and long-presses like any widget. docs/WIDGETS.md describes the
/// `window.launchus` object the page gets.
struct PluginWidgetView: NSViewRepresentable {
    let folder: URL
    let manifest: WidgetManifest
    let size: WidgetItem.Size
    /// Card size in points.
    let frame: CGSize
    /// The text scale the built-in widgets use: one cell's worth, in points.
    let unit: CGFloat
    let dark: Bool
    let live: Bool
    let generation: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassiveWebView {
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        // Each plugin's storage stays its own and off the disk of other sites.
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        let content = config.userContentController
        content.addUserScript(WKUserScript(source: Self.bridge(state: state), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addScriptMessageHandler(coordinator, contentWorld: .page, name: "launchus")
        let view = PassiveWebView(frame: CGRect(origin: .zero, size: frame), configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = coordinator
        coordinator.view = view
        coordinator.folder = folder
        coordinator.manifest = manifest
        coordinator.applied = state
        coordinator.generation = generation
        coordinator.load()
        coordinator.setLive(live)
        return view
    }

    func updateNSView(_ view: PassiveWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.manifest = manifest
        if coordinator.generation != generation || coordinator.folder != folder {
            coordinator.generation = generation
            coordinator.folder = folder
            coordinator.applied = state
            coordinator.load()
        } else if coordinator.applied != state {
            coordinator.applied = state
            coordinator.send(state)
        }
        coordinator.setLive(live)
    }

    static func dismantleNSView(_ view: PassiveWebView, coordinator: Coordinator) {
        coordinator.setLive(false)
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
    }

    struct State: Equatable, Encodable {
        var size: String
        var width: Double
        var height: Double
        var unit: Double
        var theme: String
        var locale: String
        var visible: Bool
    }

    var state: State {
        State(size: size.rawValue, width: Double(frame.width.rounded()), height: Double(frame.height.rounded()),
              unit: Double((unit * 10).rounded() / 10), theme: dark ? "dark" : "light",
              locale: Locale.preferredLanguages.first ?? "en", visible: live)
    }

    /// `window.launchus`, set up before the page's own scripts run.
    static func bridge(state: State) -> String {
        let json = (try? String(data: JSONEncoder().encode(state), encoding: .utf8)) ?? "{}"
        return """
        (() => {
          let state = \(json);
          const listeners = {};
          const fire = (name, detail) => (listeners[name] || []).slice().forEach(fn => { try { fn(detail) } catch (e) { console.error(e) } });
          const apply = () => {
            const root = document.documentElement;
            if (!root) return;
            root.dataset.size = state.size;
            root.dataset.theme = state.theme;
            root.style.colorScheme = state.theme;
            root.style.setProperty('--launchus-unit', state.unit + 'px');
            root.style.setProperty('--launchus-width', state.width + 'px');
            root.style.setProperty('--launchus-height', state.height + 'px');
          };
          apply();
          document.addEventListener('DOMContentLoaded', apply);
          const post = message => window.webkit.messageHandlers.launchus.postMessage(message);
          Object.defineProperty(window, 'launchus', { value: Object.freeze({
            spec: 1,
            get size() { return state.size },
            get width() { return state.width },
            get height() { return state.height },
            get unit() { return state.unit },
            get theme() { return state.theme },
            get locale() { return state.locale },
            get visible() { return state.visible },
            on(name, fn) { (listeners[name] = listeners[name] || []).push(fn) },
            off(name, fn) { listeners[name] = (listeners[name] || []).filter(f => f !== fn) },
            system() { return post({ type: 'system' }) },
            _update(next) {
              const was = state;
              state = next;
              apply();
              if (was.visible !== next.visible) fire(next.visible ? 'show' : 'hide');
              if (was.size !== next.size || was.width !== next.width || was.height !== next.height || was.theme !== next.theme) fire('change', next);
            },
            _refresh() { fire('refresh') },
          }), configurable: false, writable: false });
        })();
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        weak var view: PassiveWebView?
        var folder: URL?
        var manifest: WidgetManifest?
        var applied: State?
        var generation = 0
        private var timer: Timer?
        private var live = false

        func load() {
            guard let view, let folder, let manifest, let entry = manifest.file(manifest.entry, in: folder) else { return }
            let go = { [weak view] in
                // Re-made with the current state, so a reloaded page starts right.
                if let applied = self.applied {
                    view?.configuration.userContentController.removeAllUserScripts()
                    view?.configuration.userContentController.addUserScript(
                        WKUserScript(source: PluginWidgetView.bridge(state: applied), injectionTime: .atDocumentStart, forMainFrameOnly: true))
                }
                view?.loadFileURL(entry, allowingReadAccessTo: folder)
            }
            if manifest.permissions.contains(.network) {
                view.configuration.userContentController.removeAllContentRuleLists()
                go()
            } else {
                PluginRules.offline { [weak view] rules in
                    if let rules { view?.configuration.userContentController.add(rules) }
                    go()
                }
            }
        }

        func send(_ state: State) {
            guard let json = try? String(data: JSONEncoder().encode(state), encoding: .utf8) else { return }
            view?.evaluateJavaScript("window.launchus && window.launchus._update(\(json))")
        }

        /// `refresh` events only while the launcher is open.
        func setLive(_ on: Bool) {
            guard on != live else { return }
            live = on
            timer?.invalidate()
            timer = nil
            guard on, let seconds = manifest?.refresh, seconds > 0 else { return }
            timer = Timer.scheduledTimer(withTimeInterval: max(1, seconds), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.view?.evaluateJavaScript("window.launchus && window.launchus._refresh()")
                }
            }
        }

        /// The page stays in its folder: no links out, no other files.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "about" { return .allow }
            guard url.isFileURL, let folder else { return action.targetFrame?.isMainFrame == false && manifestAllowsNetwork ? .allow : .cancel }
            let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
            return url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/") ? .allow : .cancel
        }

        private var manifestAllowsNetwork: Bool { manifest?.permissions.contains(.network) == true }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return (nil, "bad message") }
            switch type {
            case "system":
                guard manifest?.permissions.contains(.system) == true else {
                    return (nil, "launchus.system() needs the \"system\" permission in manifest.json")
                }
                let s = SystemStats.shared.sample()
                var result: [String: Any] = [
                    "cpu": s.cpu,
                    "memory": ["used": Double(s.memoryUsed), "total": Double(s.memoryTotal)],
                    "disk": ["used": Double(s.diskUsed), "total": Double(s.diskTotal)],
                    "network": ["download": s.download, "upload": s.upload],
                    "uptime": ProcessInfo.processInfo.systemUptime,
                ]
                result["battery"] = s.battery.map { ["level": $0, "charging": s.charging] as [String: Any] } ?? NSNull()
                return (result, nil)
            default:
                return (nil, "unknown request \(type)")
            }
        }
    }
}

/// Draws but never takes the mouse: clicks, drags and scrolling go to the card around it.
final class PassiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// The rule list that keeps a plugin without the `network` permission offline.
@MainActor
enum PluginRules {
    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void]?

    static func offline(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return done(compiled) }
        if waiting != nil { waiting?.append(done); return }
        waiting = [done]
        let rules = """
        [{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]
        """
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "launchus.widget.offline", encodedContentRuleList: rules) { list, error in
            MainActor.assumeIsolated {
                if let error { NSLog("LaunchUS: widget rules: \(error)") }
                compiled = list
                let callbacks = waiting ?? []
                waiting = nil
                callbacks.forEach { $0(list) }
            }
        }
    }
}
