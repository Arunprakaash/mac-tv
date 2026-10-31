import SwiftUI
import WebKit

/// A person who watches on this Mac: their own home screen apps and their own sign-ins.
struct Profile: Codable, Identifiable, Equatable {
    static let mainID = "main"

    let id: String
    var name: String
    var color: String
    /// The WebKit store that keeps this profile's sign-ins. The first profile has none and uses
    /// the default store, so everything signed in before profiles existed stays signed in.
    var store: UUID?

    var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    @MainActor
    var websiteDataStore: WKWebsiteDataStore {
        store.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
    }
}

/// Everyone's profiles and who's watching now, kept in ~/Library/Application Support/Mac TV/profiles.json.
@MainActor
final class ProfileStore {
    private struct Saved: Codable {
        var profiles: [Profile]
        var current: String
    }

    static let colors = ["#0A84FF", "#FF9F0A", "#30D158", "#BF5AF2", "#FF375F", "#64D2FF"]

    private var saved: Saved
    private let file: URL
    private let folder: URL

    init(folder: URL = AppFolder.url) {
        self.folder = folder
        file = folder.appendingPathComponent("profiles.json")
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(Saved.self, from: data),
           !decoded.profiles.isEmpty {
            saved = decoded
        } else {
            let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
            saved = Saved(profiles: [Profile(id: Profile.mainID, name: first, color: Self.colors[0])], current: Profile.mainID)
        }
    }

    var all: [Profile] { saved.profiles }

    var current: Profile {
        saved.profiles.first { $0.id == saved.current } ?? saved.profiles[0]
    }

    func select(_ id: String) {
        guard saved.profiles.contains(where: { $0.id == id }) else { return }
        saved.current = id
        save()
    }

    func add(named name: String) -> Profile {
        let used = Set(saved.profiles.map(\.color))
        let color = Self.colors.first { !used.contains($0) } ?? Self.colors[saved.profiles.count % Self.colors.count]
        let profile = Profile(id: String(UUID().uuidString.prefix(8)).lowercased(), name: name, color: color, store: UUID())
        saved.profiles.append(profile)
        save()
        return profile
    }

    /// Removes a profile, its app list and its sign-ins. The first profile stays.
    func remove(_ id: String) {
        guard id != Profile.mainID, let index = saved.profiles.firstIndex(where: { $0.id == id }) else { return }
        let profile = saved.profiles.remove(at: index)
        if saved.current == id { saved.current = Profile.mainID }
        save()
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("apps-\(id).json"))
        if let store = profile.store {
            WKWebsiteDataStore.remove(forIdentifier: store) { _ in }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: file, options: .atomic) }
    }
}

/// The "Who's watching?" screen: pick a profile, add one, or remove one.
struct ProfilePicker: Equatable {
    /// A profile, or the Add tile just after the last one.
    var index = 0
    /// On the Remove button below the focused profile.
    var onRemove = false
    var confirmingRemove = false
    /// The new profile's name while it's being typed.
    var naming: String?
}

extension TVController {
    func openProfiles() {
        let index = profiles.all.firstIndex { $0.id == profile.id } ?? 0
        profilePicker = ProfilePicker(index: index)
    }

    func switchProfile(to id: String) {
        profilePicker = nil
        guard id != profile.id else { return }
        goHome()
        profiles.select(id)
        profile = profiles.current
        library = AppLibrary(profileID: profile.id, folder: library.storageFolder)
        reloadServices()
        setFocus(.app(0))
        showToast("Hi, \(profile.name)")
    }

    func handleProfiles(_ command: RemoteCommand) {
        guard var picker = profilePicker else { return }
        let all = profiles.all
        let addIndex = all.count
        if case .select = command {} else { picker.confirmingRemove = false }

        if var name = picker.naming {
            switch command {
            case .text(let text):
                name += text.replacingOccurrences(of: "\n", with: "")
                picker.naming = String(name.prefix(20))
                if text.hasSuffix("\n") { profilePicker = picker; createProfile(); return }
            case .deleteBackward:
                if !name.isEmpty { name.removeLast() }
                picker.naming = name
            case .select:
                profilePicker = picker
                createProfile()
                return
            case .back:
                picker.naming = nil
            default:
                break
            }
            profilePicker = picker
            return
        }

        let removable = picker.index < addIndex && all[picker.index].id != Profile.mainID
        switch command {
        case .back:
            // At launch there's nowhere to go back to: stay with whoever was watching last.
            profilePicker = nil
            return
        case .move(.left) where !picker.onRemove:
            picker.index = max(0, picker.index - 1)
        case .move(.right) where !picker.onRemove:
            picker.index = min(addIndex, picker.index + 1)
        case .move(.down) where removable:
            picker.onRemove = true
        case .move(.up):
            picker.onRemove = false
        case .select:
            profilePicker = picker
            activateProfile(picker.index, remove: picker.onRemove)
            return
        default:
            break
        }
        profilePicker = picker
    }

    /// Chooses a profile, starts adding one, or (pressed twice) removes the focused one.
    func activateProfile(_ index: Int, remove: Bool = false) {
        guard var picker = profilePicker else { return }
        let all = profiles.all
        picker.index = index
        if index >= all.count {
            picker.naming = ""
            picker.onRemove = false
        } else if remove {
            if picker.confirmingRemove {
                let removed = all[index]
                profiles.remove(removed.id)
                if removed.id == profile.id { profile = profiles.current; library = AppLibrary(profileID: profile.id, folder: library.storageFolder); reloadServices() }
                showToast("Removed \(removed.name)")
                picker = ProfilePicker(index: max(0, index - 1))
            } else {
                picker.confirmingRemove = true
            }
        } else {
            switchProfile(to: all[index].id)
            return
        }
        profilePicker = picker
    }

    private func createProfile() {
        guard let name = profilePicker?.naming?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
        let added = profiles.add(named: name)
        Analytics.send(.profileAdded, ["profiles": String(profiles.all.count)])
        switchProfile(to: added.id)
    }
}

// MARK: Views

/// A profile's round avatar: their initial on their colour.
struct ProfileAvatar: View {
    let profile: Profile
    var size: CGFloat = 200

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hex: profile.color), Color(hex: profile.color).opacity(0.6)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(profile.initial).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

struct ProfilesScreen: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let picker = tv.profilePicker ?? ProfilePicker()
        let all = tv.profiles.all
        VStack(spacing: 56) {
            Text(picker.naming == nil ? "Who's watching?" : "New profile")
                .font(.tv(.title2, emphasized: true))
            if let name = picker.naming {
                naming(name)
            } else {
                HStack(alignment: .top, spacing: 56) {
                    ForEach(Array(all.enumerated()), id: \.element.id) { index, profile in
                        tile(index: index, focused: picker.index == index && !picker.onRemove) {
                            ProfileAvatar(profile: profile)
                        } label: {
                            Text(profile.name)
                        }
                    }
                    tile(index: all.count, focused: picker.index == all.count) {
                        Circle().fill(.white.opacity(0.1))
                            .overlay(Circle().strokeBorder(.white.opacity(0.45), style: StrokeStyle(lineWidth: 3, dash: [10, 8])))
                            .overlay(Image(systemName: "plus").font(.system(size: 64, weight: .medium)))
                            .frame(width: 200, height: 200)
                    } label: {
                        Text("Add Profile")
                    }
                }
                removeButton(picker, all: all)
                    .frame(height: 70)
            }
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.focus, value: picker)
    }

    private func tile<Art: View, Label: View>(index: Int, focused: Bool, @ViewBuilder art: () -> Art,
                                              @ViewBuilder label: () -> Label) -> some View {
        VStack(spacing: 22) {
            art()
                .overlay(Circle().strokeBorder(.white, lineWidth: focused ? 5 : 0).padding(-10))
                .scaleEffect(focused ? 1.1 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 16)
            label()
                .font(.system(size: 27, weight: .semibold))
                .opacity(focused ? 1 : 0.6)
        }
        .contentShape(Rectangle())
        .onTapGesture { tv.activateProfile(index) }
    }

    @ViewBuilder
    private func removeButton(_ picker: ProfilePicker, all: [Profile]) -> some View {
        if picker.index < all.count, all[picker.index].id != Profile.mainID {
            let name = all[picker.index].name
            Button { tv.activateProfile(picker.index, remove: true) } label: {
                Text(picker.confirmingRemove ? "Press again to remove \(name) and their sign-ins" : "Remove \(name)")
                    .font(.tv(.caption2, emphasized: true))
                    .padding(.horizontal, 30)
                    .frame(height: 58)
                    .foregroundStyle(picker.onRemove && !picker.confirmingRemove ? .black : .white)
                    .background(Capsule().fill(picker.confirmingRemove ? Color(hex: "#FF453A")
                                               : picker.onRemove ? .white : .white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .scaleEffect(picker.onRemove ? 1.06 : 1)
        }
    }

    private func naming(_ name: String) -> some View {
        VStack(spacing: 30) {
            ProfileAvatar(profile: Profile(id: "new", name: name.isEmpty ? "?" : name,
                                           color: ProfileStore.colors[tv.profiles.all.count % ProfileStore.colors.count]))
            HStack(spacing: 0) {
                Text(name.isEmpty ? "Name" : name).opacity(name.isEmpty ? 0.4 : 1)
                Rectangle().frame(width: 3, height: 40).opacity(0.8).padding(.leading, 4)
            }
            .font(.system(size: 40, weight: .semibold))
            .padding(.horizontal, 36)
            .frame(minWidth: 520, minHeight: 84)
            .tvPanel(in: Capsule())
            Text("Type a name with the keyboard or the phone remote. Each profile has its own apps and stays signed in separately.")
                .font(.tv(.caption2)).foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center).frame(maxWidth: 820)
            ShelfButton(title: "Create Profile", focused: !name.isEmpty, glass: false) { tv.handle(.select) }
        }
    }
}
