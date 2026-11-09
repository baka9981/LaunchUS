import AppKit
import Carbon.HIToolbox
import SwiftUI

// Keyboard, scroll wheel and mouse side buttons while the launcher shows.

extension LauncherController {
    func installEventMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.handleSideButton(event)
        }) { monitors.append(m) }

        // Icon drags are tracked here rather than by the SwiftUI gesture, because the view
        // that started the drag may go away (leaving a folder, overflowing onto another page).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            guard let self, self.model.drag != nil, event.window === self.panel else { return event }
            if event.type == .leftMouseUp {
                self.model.endDrag()
                self.model.dragOutHint = false
                self.dragOutTarget = nil
            } else {
                let p = event.locationInWindow
                let point = CGPoint(x: p.x, y: self.panel.frame.height - p.y)
                let canDragOut = self.dragOutURL() != nil
                // Full screen: the bottom edge, where the Dock is. Window: anywhere outside.
                let size = self.panel.frame.size
                let outside = self.settings.displayMode == .window
                    ? !CGRect(origin: .zero, size: size).contains(point)
                    : point.y > size.height - 6
                if canDragOut, outside, self.beginDragOut(event) { return nil }
                let hint = canDragOut && self.settings.displayMode == .fullScreen && point.y > size.height - 110
                if self.model.dragOutHint != hint { self.model.dragOutHint = hint }
                self.model.dragMoved(to: point)
            }
            return event
        }) { monitors.append(m) }

        // Holding ⌥ makes the icons jiggle, like Launchpad.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            guard let self, self.isVisible else { return event }
            let option = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            if option, !self.model.isEditing, !self.model.isSearching, !self.model.isRenaming, self.model.editingNoteID == nil, self.model.sheet == nil, !self.model.showSettings {
                self.model.editingFromOption = true
                withAnimation { self.model.isEditing = true }
            } else if !option, self.model.editingFromOption {
                self.model.editingFromOption = false
                withAnimation { self.model.isEditing = false }
            }
            self.commandChanged(event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command)
            return event
        }) { monitors.append(m) }
    }

    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === panel else { return event }
        // Let the input method finish composing (e.g. pinyin candidates) before we react.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }

        let command = event.modifierFlags.contains(.command)
        if model.showSettings {
            // Settings card: its controls get the keys; Esc closes it.
            guard Int(event.keyCode) == kVK_Escape else { return event }
            model.escape()
            return nil
        }
        if model.sheet != nil {
            // An editor card is open: its text fields and buttons get the keys, except Esc.
            guard Int(event.keyCode) == kVK_Escape else { return event }
            model.escape()
            return nil
        }
        if model.editingNoteID != nil {
            // Typing on a note: only Esc is ours (it puts the note down).
            guard Int(event.keyCode) == kVK_Escape else { return event }
            model.escape()
            return nil
        }
        if model.isRenaming {
            // Typing a folder name: only Esc is ours (it ends renaming).
            guard Int(event.keyCode) == kVK_Escape else { return event }
            model.escape()
            return nil
        }
        if model.chat != nil {
            // Chatting: the field writes messages; ↩ sends, ⌘N starts over, Esc stops or leaves.
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch Int(event.keyCode) {
            case kVK_Escape: model.escape()
            case kVK_Return where flags.isEmpty, kVK_ANSI_KeypadEnter where flags.isEmpty: model.sendChat()
            case kVK_ANSI_N where flags == .command: model.newChat()
            case kVK_ANSI_W where flags == .command: hide(restoreFocus: true)
            case kVK_ANSI_Comma where flags == .command: openSettings()
            default: return event
            }
            return nil
        }
        commandChanged(false)
        if let id = model.activeCalculator, model.query.isEmpty, model.openFolderID == nil, !model.isEditing {
            if model.location(of: "widget:" + id) == nil {
                model.activeCalculator = nil
            } else if let key = Self.calculatorKey(event) {
                Calculators.shared.press(key, id)
                // Esc clears; the next Esc closes the launcher as usual.
                if Int(event.keyCode) == kVK_Escape { model.activeCalculator = nil }
                return nil
            }
        }
        // ⌘1…⌘9 open the numbered items; ⌃1…⌃9 go to that page.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let digit = Self.digit(event), flags == .command || flags == .control {
            if flags == .command { model.openShortcut(digit) } else { model.goToPage(digit - 1) }
            return nil
        }
        // Space with nothing typed opens the 猜你想找 / 最近使用 / 最常使用 / 最近安装 lists; while they
        // show, space and →/← switch between them and ⌫ closes them.
        if model.query.isEmpty, model.openFolderID == nil, !model.isEditing,
           flags.intersection([.command, .option, .control, .shift]).isEmpty {
            switch Int(event.keyCode) {
            case kVK_Space:
                model.pressSpace()
                return nil
            case kVK_RightArrow where model.spaceList != nil:
                model.spaceList = model.spaceList?.step(1)
                return nil
            case kVK_LeftArrow where model.spaceList != nil:
                model.spaceList = model.spaceList?.step(-1)
                return nil
            case kVK_Delete where model.spaceList != nil:
                model.spaceList = nil
                return nil
            case kVK_Delete where model.categoryFilter != nil:
                withAnimation(.easeInOut(duration: 0.22)) { model.categoryFilter = nil }
                return nil
            default: break
            }
        }
        switch Int(event.keyCode) {
        case kVK_Home:
            model.goToPage(0)
        case kVK_End:
            model.goToPage(model.pageCount - 1)
        case kVK_PageUp:
            model.flipPage(-1)
        case kVK_PageDown:
            model.flipPage(1)
        case kVK_Escape:
            model.escape()
        case kVK_Tab where !model.tagCandidates.isEmpty:
            model.completeTag(model.tagCandidates[0])
        case kVK_Tab where model.canAskAI:
            model.searchWeb()
        case kVK_Return where command && model.fallbackQuery != nil:
            model.searchFinder()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            model.activateSelection()
        case kVK_LeftArrow:
            command ? model.flipPage(-1) : model.moveSelection(dx: -1, dy: 0)
        case kVK_RightArrow:
            command ? model.flipPage(1) : model.moveSelection(dx: 1, dy: 0)
        case kVK_UpArrow:
            model.moveSelection(dx: 0, dy: -1)
        case kVK_DownArrow:
            model.moveSelection(dx: 0, dy: 1)
        case kVK_ANSI_W where command:
            hide(restoreFocus: true)
        case kVK_ANSI_Comma where command:
            openSettings()
        case kVK_ANSI_I where command:
            model.showInfoForSelection()
        default:
            return event
        }
        return nil
    }

    /// A calculator key for a typed character: digits, + − × ÷ = % . (keypad too), ↩ for =,
    /// ⌫ and Esc for C.
    private static func calculatorKey(_ event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return nil }
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "="
        case kVK_Delete, kVK_ForwardDelete: return "⌫"
        case kVK_Escape, kVK_ANSI_KeypadClear: return "C"
        default: break
        }
        guard let ch = event.charactersIgnoringModifiers?.first ?? event.characters?.first else { return nil }
        switch ch {
        case "0"..."9", ".", "+", "=", "%": return String(ch)
        case ",": return "."
        case "-": return "−"
        case "*", "x", "X": return "×"
        case "/": return "÷"
        case "c", "C": return "C"
        default: return nil
        }
    }

    /// 1…9 from the number row or keypad.
    private static func digit(_ event: NSEvent) -> Int? {
        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let keypad = [kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5,
                      kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        let code = Int(event.keyCode)
        if let i = keys.firstIndex(of: code) ?? keypad.firstIndex(of: code) { return i + 1 }
        return nil
    }

    func commandChanged(_ held: Bool) {
        commandHold?.cancel()
        commandHold = nil
        if held, isVisible, model.sheet == nil, !model.showSettings, model.openFolderID == nil, model.drag == nil {
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.easeOut(duration: 0.15)) { self?.model.showShortcutNumbers = true }
            }
            commandHold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else if model.showShortcutNumbers {
            withAnimation(.easeOut(duration: 0.15)) { model.showShortcutNumbers = false }
        }
    }

    func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === panel else { return event }
        // Smooth-scrolling mouse drivers send point deltas with no gesture phase at all.
        let isTrackpad = event.hasPreciseScrollingDeltas && !(event.phase.isEmpty && event.momentumPhase.isEmpty)
        if model.drag != nil {
            // The scrolling grid scrolls under a held icon as usual.
            if settings.pageStyle == .scroll, model.openFolderID == nil { return event }
            // The wheel turns pages while an icon is held.
            if !isTrackpad { wheelFlip(event) }
            return nil
        }
        // Cards (the App manager's lists) scroll themselves; the pages stay put.
        if model.showSettings || model.sheet != nil { return event }
        if settings.displayMode == .ring {
            // The ring turns its pages with the wheel, or a swipe either way.
            if !isTrackpad { wheelFlip(event); return nil }
            if !event.momentumPhase.isEmpty { return nil }
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            switch event.phase {
            case .began: rawDrag = 0
            case .changed: rawDrag += delta
            case .ended, .cancelled:
                if abs(rawDrag) > 40 { flip(rawDrag < 0 ? 1 : -1) }
                rawDrag = 0
            default: break
            }
            return nil
        }
        // The scrolling browse style scrolls natively, unless a folder is open.
        if settings.pageStyle == .scroll, model.openFolderID == nil { return event }
        if model.openFolderID != nil, model.folderScrolls {
            // Trackpads report points (momentum included); wheels report lines.
            let dy = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 36)
            model.scrollFolder(by: -dy)
            return nil
        }

        if isTrackpad {
            // Trackpad: follow the fingers, then snap to a page.
            if !event.momentumPhase.isEmpty { return nil }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let delta = abs(dx) >= abs(dy) ? dx : dy

            switch event.phase {
            case .began:
                rawDrag = 0
            case .changed:
                rawDrag += delta
                model.dragChanged(rawDrag)
            case .ended, .cancelled:
                model.dragEnded(rawDrag, pageWidth: panel.frame.width)
                rawDrag = 0
            default:
                break
            }
        } else {
            wheelFlip(event)
        }
        return nil
    }

    /// Mouse wheel: a spin sends a burst of events, each notch one (a smooth-scrolling mouse, many
    /// small ones). Notches are counted, not lines: macOS speeds lines up on a quick spin, so one
    /// notch can say five. Every 鼠标滚轮翻页 notches a page flips, flips kept a least gap apart.
    func wheelFlip(_ event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        let speed = settings.wheelSpeed
        let now = Date()
        if now.timeIntervalSince(lastWheelEvent) > WheelSpeed.pause || (wheelTurned != 0 && (wheelTurned < 0) != (delta < 0)) {
            wheelTurned = 0
        }
        lastWheelEvent = now
        let notch = event.hasPreciseScrollingDeltas ? min(1, abs(delta) / 10) : 1
        wheelTurned += delta < 0 ? -notch : notch
        if ProcessInfo.processInfo.environment["LAUNCHUS_WHEEL_LOG"] != nil {
            NSLog("wheel delta=\(delta) precise=\(event.hasPreciseScrollingDeltas) turned=\(wheelTurned)")
        }
        guard abs(wheelTurned) >= WheelSpeed.notches(speed) - 0.001,
              now.timeIntervalSince(lastWheelFlip) >= WheelSpeed.interval(speed) else { return }
        flip(wheelTurned < 0 ? 1 : -1)
        lastWheelFlip = now
        wheelTurned = 0
    }

    func flip(_ step: Int) {
        model.flipPage(step)
        // A held icon lands on the new page under the pointer.
        if model.drag != nil { model.dragMoved(to: model.dragLocation) }
    }

    /// The mouse's back and forward side buttons turn pages.
    func handleSideButton(_ event: NSEvent) -> NSEvent? {
        guard isVisible, event.window === panel, !model.showSettings, model.sheet == nil,
              model.openFolderID == nil, settings.pageStyle == .paged || model.drag != nil else { return event }
        switch event.buttonNumber {
        case 3: flip(-1)
        case 4: flip(1)
        default: return event
        }
        return nil
    }
}
