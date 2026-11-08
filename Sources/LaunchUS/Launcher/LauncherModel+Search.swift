import AppKit
import SwiftUI

extension LauncherModel {
    // MARK: - Tags in the search field

    /// The "#…" token being typed at the end of the query, if any.
    private var pendingTagToken: String? {
        guard let last = query.split(separator: " ", omittingEmptySubsequences: false).last,
              let first = last.first, first == "#" || first == "＃" else { return nil }
        return String(last.dropFirst())
    }

    /// Tags offered under the search field while a "#…" token is being typed.
    var tagCandidates: [String] {
        guard let token = pendingTagToken else { return [] }
        let used = Set(AppSearch.parse(query).tags.dropLast())
        let matches = token.isEmpty ? allTags : AppSearch.tagsMatching(token, in: allTags)
        return Array(matches.filter { !used.contains($0.lowercased()) }.prefix(12))
    }

    func completeTag(_ tag: String) {
        guard pendingTagToken != nil else { return }
        var parts = query.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        parts[parts.count - 1] = "#" + tag
        query = parts.joined(separator: " ") + " "
        focusRequest += 1
    }

    /// Tags named exactly in the query, when every "#…" token is a complete tag.
    var completeQueryTags: [String] {
        let tokens = AppSearch.parse(query).tags
        let resolved = tokens.compactMap { t in allTags.first { $0.lowercased() == t } }
        return !tokens.isEmpty && resolved.count == tokens.count ? resolved : []
    }

    func queryChanged() {
        guard chat == nil else { return }  // writing a message, not searching
        let phrase = settings.hiddenPhrase.trimmingCharacters(in: .whitespaces)
        if !phrase.isEmpty, query.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(phrase) == .orderedSame {
            // Cleared on the next turn: set from inside the text field's own edit, the field
            // keeps showing the phrase (with the placeholder drawn over it).
            DispatchQueue.main.async {
                self.query = ""
                self.revealHidden()
            }
            return
        }
        // The field never starts with a space (space there opens the lists); this catches pastes.
        if let first = query.first, first.isWhitespace {
            DispatchQueue.main.async { self.query = String(self.query.drop(while: \.isWhitespace)) }
            return
        }
        if !query.isEmpty, spaceList != nil {
            spaceList = nil  // typing goes back to searching
            return
        }
        if openFolderID != nil { closeFolder() }
        isEditing = false
        multiSelection = []
        folderPick = nil
        refresh()
        currentPage = 0
        dragOffset = 0
        selection = isSearching && !(pages.first ?? []).isEmpty ? GridPos(page: 0, slot: 0) : nil
    }

    func spaceListChanged() {
        if openFolderID != nil { closeFolder() }
        isEditing = false
        multiSelection = []
        refresh()
        currentPage = 0
        dragOffset = 0
        selection = isSearching && !(pages.first ?? []).isEmpty ? GridPos(page: 0, slot: 0) : nil
    }

    /// Space with nothing typed: opens the lists, then moves to the next one.
    func pressSpace() {
        spaceList = spaceList?.step(1) ?? .guess
    }

    func prepareForShow() {
        // Back from granting Full Disk Access: pick the uninstall up again, rescanned.
        sheet = resumeUninstall.map(LauncherSheet.confirmTrash)
        resumeUninstall = nil
        showSettings = false
        tuner = nil
        exitChat()
        query = ""
        spaceList = nil
        selection = nil
        dragOffset = 0
        isEditing = false
        multiSelection = []
        folderPick = nil
        editingNoteID = nil
        dropFolder()
        isPresented = false
        showHiddenApps = false
        showGuide = false
        showWhatsNew = false
        tip = nil
        phantomSlotArmed = false
        showShortcutNumbers = false
        refresh()
        let wait = settings.returnHome
        if wait != .never, Date().timeIntervalSince(lastHidden) >= Double(wait.rawValue) {
            currentPage = 0
            scrollToTopRequest += 1
        }
    }

    func didHide() {
        NotificationCenter.default.post(name: Self.didHideLauncher, object: nil)
        lastHidden = Date()
        categoryFilter = nil
        showHiddenApps = false
        if settings.hiddenRelock, hiddenUnlocked {
            hiddenUnlocked = false
            refresh()
        }
    }
}
