import SwiftUI

/// The passing messages shown over everything: a toast, the volume indicator and a controller
/// connecting or disconnecting. They're kept apart from `TVController`, so one appearing redraws
/// only the views that show it.
@MainActor
final class Notices: ObservableObject {
    @Published private(set) var toast: String?
    /// Shown for a moment after the remote changes the volume.
    @Published private(set) var volume: VolumeLevel?
    @Published private(set) var controller: ControllerNotice?

    private var toastTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var controllerTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    func showVolume(_ level: VolumeLevel) {
        withAnimation(.smooth(duration: 0.3)) { volume = level }
        volumeTask?.cancel()
        volumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.4)) { self?.volume = nil } }
        }
    }

    func showController(_ notice: ControllerNotice) {
        withAnimation(.smooth(duration: 0.35)) { controller = notice }
        controllerTask?.cancel()
        controllerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation(.smooth(duration: 0.4)) { self?.controller = nil } }
        }
    }
}

/// The notices' layer over every screen. It never takes the pointer.
struct NoticesOverlay: View {
    @ObservedObject var notices: Notices

    var body: some View {
        ZStack {
            if let notice = notices.controller {
                TVCanvas {
                    GlassGroup { ControllerBanner(notice: notice).tvGlassTransition() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 96)
                        .padding(.top, 43)
                }
                .ignoresSafeArea()
            }

            if let volume = notices.volume {
                TVCanvas {
                    GlassGroup {
                        VolumeHUD(volume: volume).tvGlassTransition()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 96)
                    .padding(.top, 52)
                }
                .ignoresSafeArea()
            }

            // Always in place, so the toast's glass materializes in and out rather than fading.
            TVCanvas {
                GlassGroup {
                    if let toast = notices.toast {
                        Text(toast)
                            .font(.tv(.callout))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 34).padding(.vertical, 18)
                            .tvGlass(in: Capsule())
                            .tvGlassTransition()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 52)
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .animation(Motion.appear, value: notices.toast)
    }
}
