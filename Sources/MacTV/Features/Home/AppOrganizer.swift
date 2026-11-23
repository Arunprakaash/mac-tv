import AppKit
import SwiftUI

/// Pin / earlier / later keep the same app selected so the row moves with it; remove keeps the slot.
struct AppOrganizer: Equatable {
    enum Action: Int, CaseIterable {
        case pin, earlier, later, remove
    }

    var selectedID: String?
    var action: Action = .pin
    /// 0…1 while holding Select on Remove; 0 when idle.
    var removeHoldProgress: CGFloat = 0
}

extension TVController {
    /// Tests can shorten this; otherwise 0.9s, or 0.35s with Reduce Motion.
    static var removeHoldDurationOverride: TimeInterval?
    static var removeHoldDuration: TimeInterval {
        if let removeHoldDurationOverride { return removeHoldDurationOverride }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.35 : 0.9
    }

    func openOrganizer() {
        cancelRemoveHold()
        let focusedID: String?
        if case .app(let index) = focus, services.indices.contains(index) {
            focusedID = services[index].id
        } else {
            focusedID = nil
        }
        organizer = AppOrganizer(selectedID: arrangedServices.first(where: { $0.id == focusedID })?.id
                                 ?? arrangedServices.first?.id)
    }

    /// Call after a library refresh, including edits made by the phone while this sheet is open.
    func reconcileOrganizerSelection() {
        guard var panel = organizer else { return }
        if !arrangedServices.contains(where: { $0.id == panel.selectedID }) {
            cancelRemoveHold()
            panel.selectedID = arrangedServices.first?.id
            panel.removeHoldProgress = 0
            organizer = panel
        }
    }

    func handleOrganizer(_ command: RemoteCommand) {
        guard var panel = organizer else { return }
        let apps = arrangedServices
        let index = apps.firstIndex { $0.id == panel.selectedID } ?? 0
        switch command {
        case .back:
            cancelRemoveHold()
            organizer = nil
            return
        case .selectDown:
            guard let id = panel.selectedID else { return }
            if panel.action == .remove {
                beginRemoveHold(for: id)
            } else {
                activateOrganizerAction(panel.action, for: id)
            }
            return
        case .selectUp:
            cancelRemoveHold()
            return
        case .select:
            guard let id = panel.selectedID else { return }
            if panel.action == .remove {
                // Edge Select (assistive tap): start a hold that completes unless cancelled by move.
                beginRemoveHold(for: id)
            } else {
                activateOrganizerAction(panel.action, for: id)
            }
            return
        case .move(.up), .move(.down):
            cancelRemoveHold()
            guard !apps.isEmpty else { return }
            let offset: Int
            if case .move(.up) = command { offset = -1 } else { offset = 1 }
            panel.selectedID = apps[(index + offset + apps.count) % apps.count].id
        case .move(.left), .seek(forward: false):
            cancelRemoveHold()
            panel.action = AppOrganizer.Action(rawValue: max(panel.action.rawValue - 1, 0)) ?? .pin
        case .move(.right), .seek(forward: true):
            cancelRemoveHold()
            panel.action = AppOrganizer.Action(rawValue: min(panel.action.rawValue + 1, AppOrganizer.Action.allCases.count - 1)) ?? .remove
        default:
            return
        }
        organizer = panel
    }

    func activateOrganizerAction(_ action: AppOrganizer.Action, for id: String) {
        guard organizer != nil, let index = arrangedServices.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Motion.navigate) {
            switch action {
            case .pin:
                setPinned(id, !isPinned(id))
                selectOrganizerSlot(index, action: .pin)
            case .earlier:
                moveApp(id, by: -1)
                organizer = AppOrganizer(selectedID: id, action: .earlier)
            case .later:
                moveApp(id, by: 1)
                organizer = AppOrganizer(selectedID: id, action: .later)
            case .remove:
                removeApp(id)
                selectOrganizerSlot(index, action: .remove)
            }
        }
    }

    /// Starts hold-to-remove on the trash control. Idempotent while already holding the same app.
    func beginRemoveHold(for id: String) {
        guard organizer != nil, arrangedServices.contains(where: { $0.id == id }) else { return }
        if removeHoldID == id, removeHoldTimer != nil { return }
        cancelRemoveHold()
        removeHoldID = id
        var panel = organizer ?? AppOrganizer()
        panel.selectedID = id
        panel.action = .remove
        panel.removeHoldProgress = 0
        organizer = panel
        let duration = Self.removeHoldDuration
        let started = Date()
        // `.common` so progress keeps moving during AppKit mouse tracking.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.removeHoldID == id, var panel = self.organizer else {
                    self.cancelRemoveHold()
                    return
                }
                let progress = min(CGFloat(Date().timeIntervalSince(started) / duration), 1)
                panel.removeHoldProgress = progress
                self.organizer = panel
                if progress >= 1 { self.commitRemoveHold() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        removeHoldTimer = timer
    }

    /// Releases an in-progress hold without removing.
    func cancelRemoveHold() {
        removeHoldTimer?.invalidate()
        removeHoldTimer = nil
        removeHoldID = nil
        if var panel = organizer, panel.removeHoldProgress != 0 {
            panel.removeHoldProgress = 0
            organizer = panel
        }
    }

    /// True while Select is held on Remove (tests and UI).
    var isHoldingRemove: Bool { removeHoldTimer != nil }

    /// Commits an in-progress hold immediately (tests).
    func finishRemoveHold() { commitRemoveHold() }

    private func commitRemoveHold() {
        guard let id = removeHoldID else { return }
        removeHoldTimer?.invalidate()
        removeHoldTimer = nil
        removeHoldID = nil
        if var panel = organizer {
            panel.removeHoldProgress = 0
            organizer = panel
        }
        activateOrganizerAction(.remove, for: id)
    }

    /// After pin/remove, keep the row number; if that slot is gone, the one above it.
    private func selectOrganizerSlot(_ index: Int, action: AppOrganizer.Action) {
        let apps = arrangedServices
        guard !apps.isEmpty else {
            organizer = AppOrganizer(selectedID: nil, action: action)
            return
        }
        organizer = AppOrganizer(selectedID: apps[min(index, apps.count - 1)].id, action: action)
    }
}

struct AppOrganizerSheet: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let apps = tv.arrangedServices
        VStack(alignment: .leading, spacing: 22) {
            Text("Arrange Apps").font(.tv(.title3, emphasized: true))
            Text("Favourites stay first. The first six apps appear in the dock.")
                .font(.tv(.caption1)).foregroundStyle(.white.opacity(0.7))

            ScrollViewReader { proxy in
                ScrollView {
                    // VStack (not Lazy): LazyVStack recycles by slot, so pin/move animations look like
                    // the wrong row sliding while the label updates.
                    VStack(spacing: 12) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, service in
                            appRow(service, position: index + 1)
                                .id(service.id)
                        }
                        if apps.isEmpty {
                            Text("Add an app to start arranging your home screen.")
                                .font(.system(size: 26)).padding(40)
                        }
                    }
                    .padding(8)
                    .animation(reduceMotion ? nil : Motion.navigate, value: apps.map(\.id))
                }
                .frame(height: min(550, max(280, canvas.height - 450)))
                .onAppear { scrollToSelection(proxy) }
                .onChange(of: tv.organizer?.selectedID) { _, _ in scrollToSelection(proxy) }
                .onChange(of: apps.map(\.id)) { _, _ in scrollToSelection(proxy) }
            }

            InputHintsBar(tv: tv, actions: [
                .moveVertical("Choose app"),
                .moveHorizontal("Choose action"),
                .select(tv.organizer?.action == .remove ? "Hold to remove" : "Apply"),
                .back("Close"),
            ])
        }
        .padding(48)
        .frame(width: 1340, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .onDisappear { tv.cancelRemoveHold() }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = tv.organizer?.selectedID else { return }
        withAnimation(reduceMotion ? nil : Motion.navigate) { proxy.scrollTo(id, anchor: .center) }
    }

    private func appRow(_ service: Service, position: Int) -> some View {
        let selected = tv.organizer?.selectedID == service.id
        let pinned = tv.isPinned(service.id)
        return HStack(spacing: 16) {
            Text("\(position)")
                .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.55)).frame(width: 38)
            Button {
                tv.cancelRemoveHold()
                tv.organizer?.selectedID = service.id
            } label: {
                Text(service.name).font(.system(size: 27, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            actionButton(.pin, title: pinned ? "Unpin" : "Pin", symbol: pinned ? "star.slash" : "star",
                         service: service, enabled: true)
            actionButton(.earlier, title: "Earlier", symbol: "arrow.up", service: service,
                         enabled: tv.canMoveApp(service.id, by: -1))
            actionButton(.later, title: "Later", symbol: "arrow.down", service: service,
                         enabled: tv.canMoveApp(service.id, by: 1))
            removeButton(service)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.white.opacity(selected ? 0.13 : 0.05))
                .animation(reduceMotion ? nil : Motion.focus, value: selected)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(selected ? 0.5 : 0), lineWidth: 2)
                .animation(reduceMotion ? nil : Motion.focus, value: selected)
                .allowsHitTesting(false)
        }
    }

    private func actionButton(_ action: AppOrganizer.Action, title: String, symbol: String,
                              service: Service, enabled: Bool) -> some View {
        let focused = tv.organizer?.selectedID == service.id && tv.organizer?.action == action
        return Button {
            tv.cancelRemoveHold()
            tv.activateOrganizerAction(action, for: service.id)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 132, height: 54)
                .foregroundStyle(focused ? .black : .white)
                .background(focused ? .white : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(title) \(service.name)")
        .animation(reduceMotion ? nil : Motion.focus, value: focused)
    }

    private func removeButton(_ service: Service) -> some View {
        let focused = tv.organizer?.selectedID == service.id && tv.organizer?.action == .remove
        let progress = (tv.organizer?.selectedID == service.id) ? (tv.organizer?.removeHoldProgress ?? 0) : 0
        let holding = progress > 0
        let ring = Color(hex: "#FF453A").opacity(0.45 + 0.55 * Double(progress))
        return Image(systemName: "trash")
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 54, height: 54)
            .foregroundStyle(focused || holding ? Color(hex: "#FF453A") : .white)
            .background(focused || holding ? .white : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .trim(from: 0, to: progress)
                    .stroke(ring, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .overlay {
                // AppKit press tracking: SwiftUI Button/ScrollView drop isPressed on redraw.
                OrganizerPointerHold { pressed in
                    if pressed { tv.beginRemoveHold(for: service.id) }
                    else { tv.cancelRemoveHold() }
                }
            }
            .accessibilityLabel("Hold to remove \(service.name)")
            .accessibilityAddTraits(.isButton)
            .animation(reduceMotion ? nil : Motion.focus, value: focused)
    }
}

/// Mouse down/up for hold-to-remove; survives SwiftUI redraws while progress updates.
private struct OrganizerPointerHold: NSViewRepresentable {
    var onPressed: (Bool) -> Void

    func makeNSView(context: Context) -> OrganizerPointerHoldView {
        let view = OrganizerPointerHoldView()
        view.onPressed = onPressed
        return view
    }

    func updateNSView(_ nsView: OrganizerPointerHoldView, context: Context) {
        nsView.onPressed = onPressed
    }
}

private final class OrganizerPointerHoldView: NSView {
    var onPressed: ((Bool) -> Void)?
    private var down = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = true
        onPressed?(true)
        // Track until release so ScrollView / redraws don't swallow the up.
        while down {
            guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                               until: .distantFuture,
                                               inMode: .eventTracking,
                                               dequeue: true) else { break }
            if next.type == .leftMouseUp {
                down = false
            } else {
                let loc = convert(next.locationInWindow, from: nil)
                if !bounds.insetBy(dx: -4, dy: -4).contains(loc) {
                    down = false
                }
            }
        }
        onPressed?(false)
    }

    override func mouseUp(with event: NSEvent) {
        guard down else { return }
        down = false
        onPressed?(false)
    }
}
