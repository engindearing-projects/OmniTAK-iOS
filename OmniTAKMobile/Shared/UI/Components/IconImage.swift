//
//  IconImage.swift
//  OmniTAKMobile
//
//  An icon that is either an SF Symbol name or, with an "asset:" prefix, a
//  template image from the asset catalog (e.g. "asset:XVoiceSpeakerMic", the
//  X Voice speaker-mic glyph). Lets toolbar items and plugin rows use a custom
//  glyph while everything else keeps passing plain SF Symbol names.
//

import SwiftUI

struct IconImage: View {
    let name: String
    /// Point size: SF Symbols use it as the font size; assets are drawn as a
    /// square of roughly the same visual weight.
    let size: CGFloat
    var weight: Font.Weight = .regular

    static let assetPrefix = "asset:"

    var body: some View {
        if name.hasPrefix(Self.assetPrefix) {
            Image(String(name.dropFirst(Self.assetPrefix.count)))
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 1.2, height: size * 1.2)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
        }
    }
}
