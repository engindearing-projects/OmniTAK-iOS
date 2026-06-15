//
//  UasVideoPipView.swift
//  OmniTAKMobile
//
//  Picture-in-picture live video overlay for the drone camera.
//  Mirrors Android's UasVideoPip.kt, with two source backends:
//
//   - RTSP — libVLC (MobileVLCKit) via udp:// or rtsp:// URL.
//   - Raw H264 UDP — libVLC via the `h264://` scheme (udp://@:port/h264).
//     VLC's h264 access module binds the port and demuxes Annex B NAL
//     units natively, equivalent to Android's RawH264UdpPlayer +
//     MediaCodec path. The H264NalSplitter type remains the canonical
//     parsing primitive and is exercised independently in unit tests.
//   - MPEG-TS UDP — libVLC via udp://@:port.
//
//  Layout:
//   - Compact (default): 160 × 90 pt 16:9 box, bottom-right of the map.
//   - Expanded: 320 × 180 pt. Tap the fullscreen icon to toggle.
//   - Close icon tears down the player and dismisses the PIP for the
//     session; caller re-shows it on source change.
//
//  If MobileVLCKit is not linked, renders an instructional fallback so
//  the app still builds and runs without the optional SPM package.
//

import SwiftUI

// MARK: - PIP dimensions

private enum PipSize {
    case compact, expanded

    var width:  CGFloat { self == .compact ? 160 : 320 }
    var height: CGFloat { self == .compact ?  90 : 180 }
}

// MARK: - UasVideoPipView

/// Drop-in overlay view: wrap inside a `ZStack` on the map screen and
/// pass the active `VideoSource` from `UASManager`.
///
/// Example wiring (mirrors Android's MapScreen.kt):
/// ```swift
/// let videoSource = manager.videoSource
/// var videoVisible = true
/// if droneState.isConnected() && videoSource.isActive && videoVisible {
///     UasVideoPipView(source: videoSource, onDismiss: { videoVisible = false })
/// }
/// ```
struct UasVideoPipView: View {
    let source: VideoSource
    var onDismiss: () -> Void = {}

    @State private var size: PipSize = .compact

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                #if canImport(MobileVLCKit)
                _VLCPipPlayer(source: source)
                #else
                _NoVLCFallback(source: source)
                #endif
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)

            // Control strip
            HStack(spacing: 4) {
                // Expand / collapse
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        size = size == .compact ? .expanded : .compact
                    }
                } label: {
                    Image(systemName: size == .compact
                          ? "arrow.up.left.and.arrow.down.right"
                          : "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                // Dismiss
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(6)
        }
    }
}

// MARK: - VLC player inner view

#if canImport(MobileVLCKit)
import MobileVLCKit

private struct _VLCPipPlayer: View {
    let source: VideoSource
    @StateObject private var ctrl = _VLCPipController()

    var body: some View {
        ZStack {
            Color.black

            if ctrl.isBuffering {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
            } else if let err = ctrl.errorMessage {
                VStack(spacing: 4) {
                    Image(systemName: "video.slash")
                        .foregroundColor(.red)
                        .font(.system(size: 20))
                    Text(err)
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                    Button("Retry") { ctrl.start(source: source) }
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.yellow)
                }
                .padding(4)
            } else {
                _VLCVideoViewRepresentable(ctrl: ctrl)
            }
        }
        .onAppear  { ctrl.start(source: source) }
        .onDisappear { ctrl.stop() }
        .onChange(of: source) { newSource in ctrl.start(source: newSource) }
    }
}

private final class _VLCPipController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published var isBuffering = true
    @Published var errorMessage: String?

    private(set) var player = VLCMediaPlayer()

    override init() {
        super.init()
        player.delegate = self
    }

    func start(source: VideoSource) {
        stop()
        guard let url = source.vlcURL else { return }
        errorMessage = nil
        isBuffering  = true
        let media = VLCMedia(url: url)
        // Low-latency tuning identical to VLCPlayerView.swift.
        media.addOption(":network-caching=150")
        media.addOption(":live-caching=150")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        player.media = media
        player.play()
    }

    func stop() {
        player.stop()
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.player.state {
            case .opening, .buffering:
                self.isBuffering  = true
                self.errorMessage = nil
            case .playing:
                self.isBuffering  = false
                self.errorMessage = nil
            case .paused, .stopped, .ended:
                self.isBuffering = false
            case .error:
                self.isBuffering  = false
                self.errorMessage = "Stream error — check port and source"
            @unknown default:
                break
            }
        }
    }
}

private struct _VLCVideoViewRepresentable: UIViewRepresentable {
    let ctrl: _VLCPipController

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        ctrl.player.drawable = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        ctrl.player.drawable = uiView
    }
}

#endif  // canImport(MobileVLCKit)

// MARK: - Fallback when VLCKit is absent

private struct _NoVLCFallback: View {
    let source: VideoSource

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 4) {
                Image(systemName: "video.slash.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 18))
                Text(source.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                Text("MobileVLCKit not linked")
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
            }
        }
    }
}
