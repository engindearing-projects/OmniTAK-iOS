//
//  ContactMarkerRendering.swift
//  OmniTAKMobile
//
//  Issue #132 — live-contact markers on the 2D Mapbox engine.
//
//  Before: the callsign was baked into the marker bitmap. The bitmap came from
//  hosting a SwiftUI `MilStdMarkerSymbolView` in a `UIHostingController` that
//  was never added to a window and calling `drawHierarchy(afterScreenUpdates:)`
//  on it. Off-window `drawHierarchy` is device / iOS-version dependent; on some
//  iPhones the text came back as placeholder glyphs ("???") for every operator,
//  and because the bitmap was cached by `cot|type|callsign` (and registered with
//  Mapbox under the same name) one bad render stuck for the whole session.
//
//  Now: the bitmap is the symbol only, drawn with Core Graphics (no SwiftUI
//  hosting, no window, no `drawHierarchy`), and the callsign is a Mapbox
//  `textField` on the contact annotation — the same mechanism dropped pins and
//  ADS-B aircraft already use. Text is laid out by Mapbox's own glyph pipeline,
//  not by a UIKit snapshot, and the image key no longer carries the callsign so
//  a renamed operator doesn't mint a new sprite either.
//

import UIKit
import SwiftUI
import MapboxMaps

enum ContactMarkerRender {

    // MARK: - Layout constants

    /// Point size of the affiliation frame (matches the old 28 pt symbol).
    static let symbolSize: CGFloat = 28
    /// Transparent margin around the frame for the glow + stroke half-width.
    static let symbolMargin: CGFloat = 4
    /// Mapbox text-offset (in ems) from the contact's coordinate to the top of
    /// the label — clears the 28 pt frame (14 pt radius + stroke + glow) at the
    /// 11 pt label size. #135: this and `labelTextSize` are the design values, at
    /// the phone's default text size and a Label size of 100%; `MapLabelStyle`
    /// scales the size and keeps the same distance in points at every size.
    static let labelOffsetEm: Double = 1.5
    static let labelTextSize: Double = 11

    // MARK: - Keys

    /// Mapbox style-image name for a contact symbol. Deliberately has no
    /// callsign: the bitmap doesn't contain one, so every contact of the same
    /// type / iconset / color shares one sprite.
    static func imageKey(cotType: String, iconsetPath: String?, argb: Int?) -> String {
        "cotsym|\(cotType)|\(iconsetPath ?? "")|\(argb ?? 0)"
    }

    /// Key for the coordinator's in-memory `UIImage` cache of rendered symbols.
    static func symbolCacheKey(cotType: String) -> String {
        "cotsym|\(cotType)"
    }

    // MARK: - Symbol bitmap (no text)

    /// MIL-STD-2525 affiliation frame + unit glyph for a CoT type, with NO
    /// callsign. Mirrors `MilStdMarkerSymbolView`'s symbol half (glow, tinted
    /// fill, affiliation-colored outline, SF Symbol unit glyph) using the same
    /// `Shape` geometry, but renders through `UIGraphicsImageRenderer` so it
    /// never depends on a hosted SwiftUI view or on a window being present.
    ///
    /// - Parameters:
    ///   - size: frame size in points (default 28).
    ///   - scale: bitmap scale; nil uses the device screen scale. Tests pin it.
    static func symbolImage(cotType: String,
                            size: CGFloat = symbolSize,
                            scale: CGFloat? = nil) -> UIImage {
        let props = MilStdCoTParser.parse(cotType: cotType)
        let color = UIColor(props.affiliation.color)
        let fill = UIColor(props.affiliation.fillColor)

        let side = size + symbolMargin * 2
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        if let scale { format.scale = scale }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            let frame = CGRect(x: symbolMargin, y: symbolMargin, width: size, height: size)

            // Dark glow so the frame reads on any basemap (the SwiftUI view's
            // black 0.4 blurred under-shape, one point larger than the frame).
            // (CG shadow alpha = path alpha x shadow-color alpha, so an opaque
            // shadow color keeps the glow at the path's 0.4.)
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: 2, color: UIColor.black.cgColor)
            UIColor.black.withAlphaComponent(0.4).setFill()
            cg.addPath(framePath(for: props.affiliation, in: frame.insetBy(dx: -1, dy: -1), size: size))
            cg.fillPath()
            cg.restoreGState()

            // Tinted fill + affiliation-colored outline.
            let path = framePath(for: props.affiliation, in: frame, size: size)
            fill.setFill()
            cg.addPath(path)
            cg.fillPath()
            color.setStroke()
            cg.setLineWidth(max(1.5, size * 0.08))
            cg.setLineJoin(.round)
            cg.addPath(path)
            cg.strokePath()

            // Unit glyph, centered. A generic unit (no function code, e.g. the
            // default "a-f-G-U-C" position report) gets a plain frame, as on
            // Android: its "questionmark" placeholder sat inside every
            // teammate's marker and read as a broken callsign. A symbol name
            // this iOS doesn't ship simply yields no glyph (the frame still
            // draws) — same as `Image(systemName:)`.
            let config = UIImage.SymbolConfiguration(pointSize: size * 0.45, weight: .semibold)
            if props.unitType != .unknown,
               let glyph = UIImage(systemName: props.unitType.icon, withConfiguration: config)?
                .withTintColor(color, renderingMode: .alwaysOriginal) {
                let g = glyph.size
                glyph.draw(in: CGRect(x: frame.midX - g.width / 2,
                                      y: frame.midY - g.height / 2,
                                      width: g.width, height: g.height))
            }
        }
    }

    /// The affiliation frame outline. Reuses `RotatedSquare` / `QuatrefoilShape`
    /// (and the same corner radii) as `MilStdMarkerSymbolView` so 2D contacts keep
    /// the exact shapes the radial menu and overlay sheets draw.
    private static func framePath(for affiliation: MilStdAffiliation, in rect: CGRect, size: CGFloat) -> CGPath {
        let radius = size * 0.12
        switch affiliation {
        case .friendly, .assumed:
            return RoundedRectangle(cornerRadius: radius).path(in: rect).cgPath
        case .hostile, .suspect, .joker, .faker:
            return RotatedSquare().path(in: rect).cgPath
        case .neutral:
            return RoundedRectangle(cornerRadius: radius * 0.5).path(in: rect).cgPath
        case .unknown, .pending:
            return QuatrefoilShape().path(in: rect).cgPath
        }
    }

    // MARK: - Annotation

    /// The Mapbox annotation for one live contact: symbol-only sprite centered on
    /// the coordinate (like dropped pins) and the callsign as its text field.
    /// Pulled out of the map coordinator so the assembly is unit-testable.
    ///
    /// - Parameters:
    ///   - image: the symbol bitmap (TAK-registry icon or `symbolImage`).
    ///   - stalenessOverlay: #178 — fade by age bucket and add the compact age
    ///     under the callsign. Off by default.
    ///   - labelFactor: #135: the phone's text size x the Label size setting; the
    ///     callsign (and the age under it) is drawn at this multiple of its design
    ///     size. The symbol keeps its size. 1 is the size the app always drew.
    static func annotation(for marker: CoTMarker,
                           image: UIImage,
                           stalenessOverlay: Bool = false,
                           now: Date = Date(),
                           labelFactor: Double = 1) -> PointAnnotation {
        var ann = PointAnnotation(id: "cot-\(marker.uid)", coordinate: marker.coordinate)
        // The name folds in the icon source so a spot-map dot and an affiliation
        // frame of the same type don't share one sprite. No callsign in it.
        ann.image = .init(
            image: image,
            name: imageKey(cotType: marker.type, iconsetPath: marker.iconsetPath, argb: marker.argbColor)
        )
        ann.iconSize = 1.0
        ann.iconAnchor = .center

        var labelOpacity: Double? = nil
        var ageLabel: String? = nil
        if stalenessOverlay {
            if let receivedAt = marker.receivedAt {
                let alpha = CoTAge.alpha(receivedAt: receivedAt, now: now)
                ann.iconOpacity = alpha
                labelOpacity = alpha
            }
            ageLabel = CoTAge.shortLabel(receivedAt: marker.receivedAt, now: now)
        }
        applyLabel(to: &ann, callsign: marker.callsign, ageLabel: ageLabel, opacity: labelOpacity,
                   labelFactor: labelFactor)
        return ann
    }

    // MARK: - Label (Mapbox text field)

    /// The label text for a contact: the callsign, plus the compact age on a
    /// second line when the staleness overlay (#178) supplies one. Nil when
    /// there is nothing to show.
    static func labelText(callsign: String, ageLabel: String? = nil) -> String? {
        let name = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (name.isEmpty, ageLabel) {
        case (false, let age?): return "\(name)\n\(age)"
        case (false, nil):      return name
        case (true, let age?):  return age
        case (true, nil):       return nil
        }
    }

    /// Put the callsign on the annotation as a Mapbox text field, styled like
    /// dropped pins (white, black halo, anchored under the symbol).
    ///
    /// - Parameters:
    ///   - opacity: label opacity; the staleness overlay passes the same alpha it
    ///     gives the icon so the whole pin fades together.
    ///   - labelFactor: #135: see `annotation(for:image:stalenessOverlay:now:labelFactor:)`.
    ///     The name starts the same distance below the point at every size
    ///     (`MapLabelStyle`), so a bigger name never reaches the symbol.
    static func applyLabel(to annotation: inout PointAnnotation,
                           callsign: String,
                           ageLabel: String? = nil,
                           opacity: Double? = nil,
                           labelFactor: Double = 1) {
        guard let text = labelText(callsign: callsign, ageLabel: ageLabel) else { return }
        let style = MapLabelStyle.contact(factor: labelFactor)
        annotation.textField = text
        annotation.textAnchor = .top
        annotation.textOffset = [0, style.offsetEm]
        annotation.textColor = StyleColor(.white)
        annotation.textHaloColor = StyleColor(.black)
        annotation.textHaloWidth = style.haloWidth
        annotation.textSize = style.textSize
        if let opacity { annotation.textOpacity = opacity }
    }
}
