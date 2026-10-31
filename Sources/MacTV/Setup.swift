import SwiftUI

/// The first-run setup: a welcome, choosing the home screen's apps, pairing the phone remote, the
/// anonymous-usage question, and a few tips. Shown once on a new install, driven by the D-pad, the
/// keyboard or the mouse. An existing install sees only the usage question, once, after updating.
struct SetupFlow: Equatable {
    enum Step: Int, CaseIterable {
        case welcome, apps, remote, privacy, done
    }

    var step: Step = .welcome
    /// In the apps step: the focused app, or the Continue button when it's past the last app.
    /// In the privacy step: 0 is Share, 1 is Not Now.
    var index = 0
    /// A phone opened the remote while the remote step was showing.
    var phoneConnected = false
    /// Just the usage question, for an install that finished setup before it existed.
    var onlyPrivacy = false

    /// The steps this run shows, in order.
    @MainActor var steps: [Step] {
        if onlyPrivacy { return [.privacy] }
        return Step.allCases.filter { $0 != .privacy || Analytics.available }
    }

    static let columns = 5
}

extension TVController {
    /// A new install: nothing paired, no apps added or removed, and setup never finished.
    var needsSetup: Bool {
        !UserDefaults.standard.bool(forKey: "setupDone") && !phonePaired && !library.hasSavedApps
    }

    /// The built-in apps setup offers, in home-screen order.
    var setupChoices: [Service] {
        Catalog.services.filter { $0.kind != .addApp && $0.kind != .settings && $0.isInstalled }
    }

    func startSetup() {
        setup = SetupFlow()
    }

    /// An install from before the usage question: ask it once, on its own.
    func askAboutAnalytics() {
        setup = SetupFlow(step: .privacy, onlyPrivacy: true)
    }

    func finishSetup() {
        guard let flow = setup else { return }
        if !flow.onlyPrivacy {
            UserDefaults.standard.set(true, forKey: "setupDone")
            let hidden = setupChoices.filter { library.isHidden($0.id) }.count
            Analytics.send(.setupFinished, ["phoneConnected": String(flow.phoneConnected), "appsHidden": String(hidden)])
        }
        setup = nil
        setFocus(.app(0))
    }

    func handleSetup(_ command: RemoteCommand) {
        guard var flow = setup else { return }
        switch command {
        case .back:
            let steps = flow.steps
            if let at = steps.firstIndex(of: flow.step), at > 0 { flow.step = steps[at - 1]; flow.index = 0 }
        case .select:
            setup = flow
            activateSetup(flow.step == .apps || flow.step == .privacy ? flow.index : 0)
            return
        case .move(let direction) where flow.step == .apps:
            flow.index = movedSetupFocus(from: flow.index, direction)
        case .move(.left) where flow.step == .privacy:
            flow.index = 0
        case .move(.right) where flow.step == .privacy:
            flow.index = 1
        default:
            break
        }
        setup = flow
    }

    /// Selects an app (checking or unchecking it) or the step's button.
    func activateSetup(_ index: Int) {
        guard var flow = setup else { return }
        let choices = setupChoices
        if flow.step == .apps, choices.indices.contains(index) {
            flow.index = index
            setup = flow
            let id = choices[index].id
            library.setHidden(id, !library.isHidden(id))
            reloadServices()
            return
        }
        if flow.step == .privacy {
            // Share (0) or Not Now (1). Nothing has been sent before this answer.
            Analytics.setConsent(index == 0, context: analyticsContext)
        }
        advanceSetup()
    }

    func advanceSetup() {
        guard var flow = setup else { return }
        let steps = flow.steps
        guard let at = steps.firstIndex(of: flow.step), at + 1 < steps.count else {
            finishSetup()
            return
        }
        let next = steps[at + 1]
        flow.step = next
        flow.index = 0
        setup = flow
    }

    /// Called whenever a phone fetches the remote's state: on the remote step, that means it's paired.
    func notePhoneDuringSetup() {
        guard let flow = setup, flow.step == .remote, !flow.phoneConnected else { return }
        setup?.phoneConnected = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            if self?.setup?.step == .remote { self?.advanceSetup() }
        }
    }

    private func movedSetupFocus(from index: Int, _ direction: RemoteCommand.Direction) -> Int {
        let count = setupChoices.count, columns = SetupFlow.columns
        let button = count
        switch direction {
        case .left:
            return index < button && index % columns > 0 ? index - 1 : index
        case .right:
            return index < button && index % columns < columns - 1 && index + 1 < count ? index + 1 : index
        case .down:
            if index == button { return index }
            return index + columns < count ? index + columns : button
        case .up:
            if index == button { return max(count - 1, 0) / columns * columns }
            return index >= columns ? index - columns : index
        }
    }
}

struct SetupScreen: View {
    @ObservedObject var tv: TVController
    @Environment(\.canvasSize) private var canvas

    var body: some View {
        let flow = tv.setup ?? SetupFlow()
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                switch flow.step {
                case .welcome: welcome
                case .apps: apps(flow)
                case .remote: remote(flow)
                case .privacy: privacy(flow)
                case .done: done
                }
            }
            .id(flow.step)
            .transition(.opacity.combined(with: .offset(y: 24)))
            Spacer(minLength: 0)
            if !flow.onlyPrivacy {
                dots(flow)
                    .padding(.bottom, 64)
            }
        }
        .foregroundStyle(.white)
        .frame(width: canvas.width, height: canvas.height)
        .animation(Motion.navigate, value: flow.step)
        .animation(Motion.focus, value: flow.index)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            title("Welcome to Mac TV")
            subtitle("Your streaming apps on the big screen, with your phone as the remote. Setting up takes about a minute.")
            HStack(spacing: 18) {
                hint("arrow.up.and.down.and.arrow.left.and.right", "Arrow keys move")
                hint("return", "Return selects")
                hint("escape", "Esc goes back")
            }
            .padding(.top, 8)
            ShelfButton(title: "Get Started", focused: true, glass: false) { tv.activateSetup(0) }
                .padding(.top, 20)
        }
    }

    private func apps(_ flow: SetupFlow) -> some View {
        let choices = tv.setupChoices
        let rows = stride(from: 0, to: choices.count, by: SetupFlow.columns).map { Array($0..<min($0 + SetupFlow.columns, choices.count)) }
        return VStack(spacing: 28) {
            title("Choose your apps")
            subtitle("Pick what goes on your home screen. You can add any website, Mac app or Steam game later with Add App.")
            VStack(spacing: 34) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 40) {
                        ForEach(row, id: \.self) { index in
                            choice(choices[index], index: index, focused: flow.index == index)
                        }
                    }
                }
            }
            .padding(.top, 20)
            ShelfButton(title: "Continue", focused: flow.index == choices.count, glass: false) { tv.advanceSetup() }
                .padding(.top, 16)
        }
    }

    private func remote(_ flow: SetupFlow) -> some View {
        VStack(spacing: 28) {
            title("Use your phone as the remote")
            subtitle("Scan a code with your phone's camera. It opens a remote in the browser, with nothing to install. Add it to your home screen to keep it handy.")
            HStack(spacing: 36) {
                if tv.remoteLinks.isEmpty {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.1))
                        .frame(width: 300, height: 300)
                        .overlay(Text("Connect to Wi-Fi\nor Tailscale").multilineTextAlignment(.center)
                            .font(.tv(.caption2)).opacity(0.7))
                }
                ForEach(tv.remoteLinks) { link in
                    VStack(spacing: 14) {
                        if let qr = link.qr {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 240, height: 240)
                                .padding(20)
                                .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        }
                        Text(link.label).font(.tv(.caption2)).opacity(0.8)
                    }
                }
            }
            .padding(.top, 12)
            .opacity(flow.phoneConnected ? 0.35 : 1)
            .overlay {
                if flow.phoneConnected {
                    Label("Remote connected", systemImage: "checkmark.circle.fill")
                        .font(.tv(.body, emphasized: true))
                        .padding(.horizontal, 34).frame(height: 76)
                        .background(Capsule().fill(Color(white: 0.16)))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(Motion.appear, value: flow.phoneConnected)
            Text("Away from home, or on Wi-Fi that keeps devices apart? Use the Tailscale code.")
                .font(.tv(.caption2)).opacity(0.55)
            ShelfButton(title: flow.phoneConnected ? "Continue" : "Skip for Now", focused: true, glass: false) { tv.advanceSetup() }
                .padding(.top, 8)
        }
    }

    private func privacy(_ flow: SetupFlow) -> some View {
        // One line and two buttons, like Apple TV's own analytics question; the details are on the privacy page.
        VStack(spacing: 28) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 92, weight: .regular))
            title("Help improve Mac TV?")
            subtitle("Share which features you use, anonymously. Never what you watch.")
            HStack(spacing: 24) {
                ShelfButton(title: "Share", focused: flow.index == 0, glass: false) { tv.activateSetup(0) }
                ShelfButton(title: "Don't Share", focused: flow.index == 1, glass: false) { tv.activateSetup(1) }
            }
            .padding(.top, 20)
        }
    }

    private var done: some View {
        VStack(spacing: 28) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 110))
                .foregroundStyle(Color(hex: "#3DDC84"))
            title("You're all set")
            VStack(alignment: .leading, spacing: 22) {
                tip("person.crop.circle", "Sign in to each app once", "Mac TV remembers it, like Safari. Type with your keyboard or the phone remote's keys.")
                tip("house", "Come home any time", "Home on the phone remote, the Menu button on a controller, or ⌘⇧H.")
                tip("arrow.up.left.and.arrow.down.right", "Fill the TV", "The green button or ⌃⌘F switches to full screen.")
                tip("gearshape", "Change things later", "Settings has the remote's QR code, the sleep timer and power options.")
            }
            .frame(width: 900, alignment: .leading)
            .padding(.top, 8)
            ShelfButton(title: "Start Watching", focused: true, glass: false) { tv.advanceSetup() }
                .padding(.top, 20)
        }
    }

    // MARK: Pieces

    private func title(_ text: String) -> some View {
        Text(text).font(.tv(.title2, emphasized: true))
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .font(.tv(.body))
            .foregroundStyle(.white.opacity(0.7))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .frame(maxWidth: 1000)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.tv(.caption2))
            .padding(.horizontal, 22).frame(height: 52)
            .foregroundStyle(.white.opacity(0.85))
            .tvPanel(in: Capsule())
    }

    private func tip(_ symbol: String, _ heading: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 22) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.tv(.body, emphasized: true))
                Text(detail).font(.tv(.caption2)).foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private func choice(_ service: Service, index: Int, focused: Bool) -> some View {
        let on = !tv.library.isHidden(service.id)
        return VStack(spacing: 16) {
            AppTile(service: service, focused: focused, tilt: .zero)
                .opacity(on ? 1 : 0.4)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 34, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(on ? .black : .white.opacity(0.8), on ? .white : .clear)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                        .padding(12)
                        .scaleEffect(focused ? 1.14 : 1)
                        .offset(y: focused ? -10 : 0)
                        .animation(Motion.focus, value: focused)
                }
            Text(service.name)
                .font(.tv(.caption2))
                .opacity(focused ? 1 : 0.7)
        }
        .contentShape(Rectangle())
        .onTapGesture { tv.activateSetup(index) }
    }

    private func dots(_ flow: SetupFlow) -> some View {
        HStack(spacing: 12) {
            ForEach(flow.steps, id: \.self) { each in
                Capsule()
                    .fill(.white.opacity(each == flow.step ? 0.9 : 0.25))
                    .frame(width: each == flow.step ? 28 : 10, height: 10)
            }
        }
        .animation(Motion.focus, value: flow.step)
    }
}
