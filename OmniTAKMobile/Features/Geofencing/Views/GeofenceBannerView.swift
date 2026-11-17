//
//  GeofenceBannerView.swift
//  OmniTAKMobile
//
//  The alert that crosses the top of the map when someone enters or leaves a geofence, or
//  stays in one. It sits in the shared map chrome, above both map engines.
//

import SwiftUI

/// One banner: the sentence, an icon for what happened, and a close button. Tapping it opens
/// the geofence list.
struct GeofenceBannerView: View {
    let banner: GeofenceBanner
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.dashed")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(banner.type.color)

            Text(banner.sentence)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(6)
            }
            .accessibilityLabel(L("geofence.banner.close"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Shows the service's current banner and follows it as the queue moves on. Its own view, so the
/// map screen is not redrawn for every change to the geofence service.
struct GeofenceBannerHost: View {
    @ObservedObject private var service = GeofenceService.shared
    /// How far below the top of the screen it sits: clear of the status strip, the aircraft pill
    /// and the compasses.
    let topInset: CGFloat
    let onOpenList: () -> Void

    var body: some View {
        VStack {
            if let banner = service.banner {
                GeofenceBannerView(
                    banner: banner,
                    onOpen: {
                        service.dismissBanner()
                        onOpenList()
                    },
                    onClose: { service.dismissBanner() })
                .padding(.horizontal, 16)
                .padding(.top, topInset)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(banner.id)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: service.banner)
        .allowsHitTesting(service.banner != nil)
    }
}
