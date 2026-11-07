import AppKit
import SwiftUI

// Layout profiles, launch items and picked icons.

extension LauncherModel {
    // MARK: - Layout profiles

    var profileNames: [String] { _ = profilesVersion; return LayoutProfiles.names(profiles) }
    var currentProfile: String { _ = profilesVersion; return profiles.current }

    /// Keeps the current layout under its profile and loads the other one.
    func switchProfile(_ name: String) {
        guard name != profiles.current, drag == nil else { return }
        profiles.saved[profiles.current] = layout
        let target = profiles.saved[name] ?? layout
        profiles.current = name
        LayoutProfiles.save(profiles)
        profilesVersion += 1
        AutoBackup.snapshot()
        layout = LayoutOps.reconcile(target, installed: catalog.apps, hidden: hiddenIDs, perPage: perPage, free: freePlacement)
        LayoutStore.save(layout: layout)
        dropFolder()
        currentPage = 0
        refresh()
        showNotice(String(localized: "已切换到布局「\(LayoutProfiles.title(name))」"))
    }

    /// Switches by a name typed in a link or Shortcuts. Returns false when there's no such profile.
    @discardableResult
    func switchProfile(named text: String) -> Bool {
        guard let name = LayoutProfiles.resolve(text, in: profiles) else { return false }
        switchProfile(name)
        return true
    }

    /// A new profile starts as a copy of the current layout.
    func createProfile(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, LayoutProfiles.resolve(name, in: profiles) == nil else { return }
        profiles.saved[name] = layout
        switchProfile(name)
    }

    func deleteProfile(_ name: String) {
        guard !name.isEmpty else { return }
        if profiles.current == name { switchProfile("") }
        profiles.saved[name] = nil
        LayoutProfiles.save(profiles)
        profilesVersion += 1
    }

    // MARK: - Launch items and icons


    func customItem(_ id: String) -> CustomItem? { customItems.first { $0.id == id } }

    /// Adds or updates a launch item; new ones go to the end of the last page.
    func saveCustomItem(_ item: CustomItem) {
        if let i = customItems.firstIndex(where: { $0.id == item.id }) {
            customItems[i] = item
        } else {
            customItems.append(item)
        }
        CustomItemStore.save(customItems)
    }

    func deleteCustomItem(_ id: String) {
        customItems.removeAll { $0.id == id }
        CustomItemStore.save(customItems)
        if meta[id] != nil {
            meta[id] = nil
            LayoutStore.save(meta: meta)
            pruneIcons()
        }
    }

    /// Takes over a backup's launch items before `apply`, so restoring the layout doesn't drop
    /// them as uninstalled. The catalog picks them up at once.
    func withCustomItems(_ items: [CustomItem]?, _ apply: () -> Void) {
        if let items, items != customItems {
            customItems = items
            CustomItemStore.save(items)
        }
        apply()
    }

    /// `nil` goes back to the app's own icon.
    func setIcon(_ value: String?, for id: String) {
        setMeta(id) { $0.icon = value }
        pruneIcons()
    }

    private func pruneIcons() {
        CustomIcons.prune(keeping: Set(meta.values.compactMap(\.icon)))
    }

    var hiddenApps: [AppItem] {
        catalog.apps.filter { meta[$0.id]?.hidden == true }
            .map { app in meta[app.id]?.displayName.flatMap { $0.isEmpty ? nil : app.renamed($0) } ?? app }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
