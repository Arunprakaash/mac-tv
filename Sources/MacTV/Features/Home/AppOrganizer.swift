import SwiftUI

/// App identities, rather than row indices, keep selection on the same app as its position changes.
struct AppOrganizer: Equatable {
    enum Action: Int, CaseIterable {
        /// The checkbox at the start of the row.
        case check
        case pin, earlier, later
    }

    var selectedID: String?
    var action: Action = .pin
    /// Apps ticked for deleting, by identity.
    var checked: Set<String> = []
    /// Delete was pressed once: the next press deletes, anything else changes nothing.
    var confirmingDelete = false
}

extension TVController {
    func openOrganizer() {
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
        let ids = Set(arrangedServices.map(\.id))
        if !ids.contains(panel.selectedID ?? "") { panel.selectedID = arrangedServices.first?.id }
        panel.checked.formIntersection(ids)
        if panel != organizer { organizer = panel }
    }

    func handleOrganizer(_ command: RemoteCommand) {
        guard var panel = organizer else { return }
        let apps = arrangedServices
        let index = apps.firstIndex { $0.id == panel.selectedID } ?? 0
        if case .deleteBackward = command {} else { panel.confirmingDelete = false }
        switch command {
        case .back:
            organizer = nil
            return
        case .move(.up), .move(.down):
            guard !apps.isEmpty else { return }
            let offset: Int
            if case .move(.up) = command { offset = -1 } else { offset = 1 }
            panel.selectedID = apps[min(max(index + offset, 0), apps.count - 1)].id
        case .move(.left):
            panel.action = AppOrganizer.Action(rawValue: max(panel.action.rawValue - 1, 0)) ?? .check
        case .move(.right):
            panel.action = AppOrganizer.Action(rawValue: min(panel.action.rawValue + 1, AppOrganizer.Action.allCases.count - 1)) ?? .later
        case .select:
            guard let id = panel.selectedID else { return }
            activateOrganizerAction(panel.action, for: id)
            return
        case .deleteBackward:
            // Added apps can't be brought back, so Delete asks for a second press, like Sleep Mac.
            guard !panel.checked.isEmpty else { return }
            guard panel.confirmingDelete else {
                panel.confirmingDelete = true
                break
            }
            deleteCheckedApps()
            return
        default:
            return
        }
        organizer = panel
    }

    func activateOrganizerAction(_ action: AppOrganizer.Action, for id: String) {
        guard let panel = organizer, arrangedServices.contains(where: { $0.id == id }) else { return }
        organizer = AppOrganizer(selectedID: id, action: action, checked: panel.checked)
        switch action {
        case .check: organizer?.checked.formSymmetricDifference([id])
        case .pin: setPinned(id, !isPinned(id))
        case .earlier: moveApp(id, by: -1)
        case .later: moveApp(id, by: 1)
        }
    }

    /// A click on a checkbox: ticks or unticks the app without moving the remote's focus onto it.
    func toggleChecked(_ id: String) {
        guard organizer != nil, arrangedServices.contains(where: { $0.id == id }) else { return }
        organizer?.checked.formSymmetricDifference([id])
        organizer?.confirmingDelete = false
    }

    /// Deletes the ticked apps: added apps go, built-in ones are hidden until restored in Settings.
    /// The selection stays where it was, on the app that moves up into its place.
    func deleteCheckedApps() {
        guard let panel = organizer, !panel.checked.isEmpty else { return }
        let apps = arrangedServices
        let index = apps.firstIndex { $0.id == panel.selectedID } ?? 0
        var failed = Set<String>()
        var deleted: [String] = []
        for app in apps where panel.checked.contains(app.id) {
            if removeApp(app.id, announce: false) { deleted.append(app.name) } else { failed.insert(app.id) }
        }
        // One message for the lot.
        if !failed.isEmpty {
            showToast("Couldn't delete \(failed.count == 1 ? "1 app" : "\(failed.count) apps"). Check available storage and folder permissions.")
        } else if deleted.count == 1 {
            showToast("Deleted \(deleted[0])")
        } else if !deleted.isEmpty {
            showToast("Deleted \(deleted.count) apps")
        }
        let remaining = arrangedServices
        let keep = remaining.contains { $0.id == panel.selectedID }
            ? panel.selectedID
            : apps[index...].first { remaining.map(\.id).contains($0.id) }?.id ?? remaining.last?.id
        organizer?.selectedID = keep
        organizer?.checked = failed
        organizer?.confirmingDelete = false
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
            Text(tv.organizer?.checked.isEmpty == false
                 ? "Built-in apps you delete can be brought back in Settings › Apps."
                 : "Favourites stay first. The first six apps appear in the dock.")
                .font(.tv(.caption1)).foregroundStyle(.white.opacity(0.7))

            ScrollViewReader { proxy in
                ScrollView {
                    // Eager, not lazy: deleting several rows at once from a lazy stack left part of the
                    // sheet undrawn on 1x external displays until the next focus change.
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
                }
                .frame(height: min(550, max(280, canvas.height - 450)))
                .onAppear { scrollToSelection(proxy) }
                .onChange(of: tv.organizer?.selectedID) { _, _ in scrollToSelection(proxy) }
                .onChange(of: apps.map(\.id)) { _, _ in scrollToSelection(proxy) }
            }

            HStack(spacing: 18) {
                InputHintsBar(tv: tv, set: .arrange)
                Spacer(minLength: 24)
                // The bulk, destructive action sits apart from the navigation hints, in system red.
                if let panel = tv.organizer, !panel.checked.isEmpty {
                    let apps = panel.checked.count == 1 ? "1 app" : "\(panel.checked.count) apps"
                    InputHint(action: .delete(panel.confirmingDelete ? "Press again to delete \(apps)" : "Delete \(apps)"),
                              kind: tv.lastInputKind, controller: tv.controller)
                        .font(.tv(.caption2, emphasized: panel.confirmingDelete))
                        .foregroundStyle(Color(hex: "#FF453A"))
                        .contentShape(Rectangle())
                        .onTapGesture { tv.handle(.deleteBackward, from: .pointer) }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.trailing, 8) // Lines the hint up with the rows' trailing edge.
        }
        .padding(48)
        .frame(width: 1340, alignment: .leading)
        .tvPanel(in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = tv.organizer?.selectedID else { return }
        withAnimation(reduceMotion ? nil : Motion.navigate) { proxy.scrollTo(id, anchor: .center) }
    }

    private func appRow(_ service: Service, position: Int) -> some View {
        let selected = tv.organizer?.selectedID == service.id
        let pinned = tv.isPinned(service.id)
        let checked = tv.organizer?.checked.contains(service.id) == true
        let checkFocused = selected && tv.organizer?.action == .check
        return HStack(spacing: 16) {
            Text("\(position)")
                .font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.55)).frame(width: 38)
            Button {
                tv.toggleChecked(service.id)
            } label: {
                OrganizerCheckbox(checked: checked, focused: checkFocused)
            }
            .buttonStyle(OrganizerCheckboxStyle())
            .accessibilityLabel("Select \(service.name) to delete")
            .accessibilityValue(checked ? "Selected" : "Not selected")
            Button {
                tv.organizer?.selectedID = service.id
            } label: {
                HStack(spacing: 14) {
                    Text(service.name).font(.system(size: 27, weight: .semibold)).lineLimit(1)
                    if pinned {
                        Image(systemName: "star.fill").font(.system(size: 20)).foregroundStyle(.yellow)
                            .accessibilityLabel("Favourite")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            actionButton(.pin, title: pinned ? "Unpin" : "Pin", symbol: pinned ? "star.slash" : "star",
                         service: service, enabled: true)
            actionButton(.earlier, title: "Earlier", symbol: "arrow.up", service: service,
                         enabled: tv.canMoveApp(service.id, by: -1))
            actionButton(.later, title: "Later", symbol: "arrow.down", service: service,
                         enabled: tv.canMoveApp(service.id, by: 1))
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(.white.opacity(selected ? 0.13 : 0.05), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.white.opacity(selected ? 0.5 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : Motion.focus, value: selected)
    }

    private func actionButton(_ action: AppOrganizer.Action, title: String, symbol: String,
                              service: Service, enabled: Bool) -> some View {
        let focused = tv.organizer?.selectedID == service.id && tv.organizer?.action == action
        return Button {
            tv.activateOrganizerAction(action, for: service.id)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 146, height: 54)
                .foregroundStyle(focused ? .black : .white)
                .background(focused ? .white : .white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(title) \(service.name)")
        .animation(reduceMotion ? nil : Motion.focus, value: focused)
    }
}

/// A checkbox at TV size: a quiet outline when off, white with a dark checkmark when on, like Mac TV's
/// other focus and selection. Remote focus draws a white ring around it; a mouse click leaves no highlight behind.
struct OrganizerCheckbox: View {
    let checked: Bool
    let focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            shape.fill(checked ? Color.white : .white.opacity(0.06))
            shape.strokeBorder(checked ? .clear : .white.opacity(0.3), lineWidth: 1.5)
            if checked {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            }
        }
        .frame(width: 28, height: 28)
        .padding(4)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(focused ? 0.9 : 0), lineWidth: 3)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
}

/// Dims while pressed, like a system control, and keeps no state once the press ends.
struct OrganizerCheckboxStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
