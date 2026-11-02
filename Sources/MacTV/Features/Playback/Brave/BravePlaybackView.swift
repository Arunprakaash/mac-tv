import AppKit
import SwiftUI

/// What the TV shows behind Mac TV's Brave window: seen while Brave opens, after an error, or when
/// Mac TV is brought back in front.
struct BravePlaybackView: View {
    @ObservedObject var tv: TVController

    var body: some View {
        ZStack {
            Wallpaper()
            VStack(spacing: 28) {
                Text(tv.externalBrowserService?.name ?? "Website")
                    .font(.tv(.title2, emphasized: true))
                Text(message)
                    .font(.tv(.body))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 1000)
                HStack(spacing: 24) {
                    let buttons = tv.browserButtons
                    ForEach(Array(buttons.enumerated()), id: \.element) { index, button in
                        ShelfButton(title: button.title, focused: tv.browserFocusIndex == index, glass: false) {
                            tv.activateBrowserButton(button)
                        }
                    }
                }
                .padding(.top, 20)
            }
            .padding(64)
        }
        .foregroundStyle(.white)
    }

    private var message: String {
        if let error = tv.externalBrowserError { return error }
        if tv.externalBrowserOpening { return "Opening in Brave…" }
        return "Playing in Brave."
    }
}

extension TVController {
    enum BrowserButton: Hashable {
        case retry, returnToBrave, home

        var title: String {
            switch self {
            case .retry: "Try Again"
            case .returnToBrave: "Return to Brave"
            case .home: "Home"
            }
        }
    }

    var browserButtons: [BrowserButton] {
        if externalBrowserError != nil { return [.retry, .home] }
        if externalBrowserOpening { return [.home] }
        return [.returnToBrave, .home]
    }

    var browserFocusIndex: Int { min(browserFocus, browserButtons.count - 1) }

    func activateBrowserButton(_ button: BrowserButton) {
        switch button {
        case .retry: retryExternalBrowser()
        case .returnToBrave: activateExternalBrowser()
        case .home: goHome()
        }
    }

    /// The remote, while Mac TV's own Brave screen is in front rather than the Brave window.
    func handleBrowserScreen(_ command: RemoteCommand) {
        let buttons = browserButtons
        switch command {
        case .move(.left), .previousControl: browserFocus = max(0, browserFocusIndex - 1)
        case .move(.right), .nextControl: browserFocus = min(buttons.count - 1, browserFocusIndex + 1)
        case .select: activateBrowserButton(buttons[browserFocusIndex])
        case .back: goHome()
        default: break
        }
    }
}
