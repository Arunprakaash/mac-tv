import SwiftUI

struct BravePlaybackView: View {
    @ObservedObject var tv: TVController
    var body: some View {
        ZStack {
            Wallpaper()
            VStack(spacing: 24) {
                Text(tv.externalBrowserService?.name ?? "Website")
                    .font(.tv(.title1, emphasized: true))
                Text("Brave website player").font(.tv(.title3))
                if let error = tv.externalBrowserError {
                    Text(error).font(.tv(.body)).multilineTextAlignment(.center)
                } else {
                    Text("Use the phone remote’s touchpad or Previous / Next control buttons.")
                        .font(.tv(.body)).multilineTextAlignment(.center)
                }
                Text("Brave’s profile, sign-ins and Shields apply. Mac TV does not guarantee ad-free playback.")
                    .font(.tv(.callout)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                HStack(spacing: 24) {
                    if tv.externalBrowserError != nil {
                        Button("Retry") { tv.retryExternalBrowser() }
                            .disabled(tv.externalBrowserOpening)
                    }
                    Button("Return to Brave") { tv.activateExternalBrowser() }
                    Button("Full screen") { tv.handle(.browserFullscreen) }
                    Button("Home") { tv.goHome() }
                }.font(.tv(.body, emphasized: true)).buttonStyle(.borderedProminent)
            }.padding(40).frame(maxWidth: 1100)
        }.foregroundStyle(.white)
    }
}
