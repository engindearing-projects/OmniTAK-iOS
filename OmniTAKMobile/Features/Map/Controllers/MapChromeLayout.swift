//
//  MapChromeLayout.swift
//  OmniTAKMobile
//
//  Where the map's floating controls sit at the bottom of the screen. They used to be placed with
//  numbers tuned for the bottom bar alone, so the bar's first-run tip, a landscape phone and an
//  iPad each put one control on another. Now everything is placed from where the bar actually is
//  (measured, with its tip or edit header when shown) and stacked from there. Pure, so the layout
//  can be tested for every screen without a screen.
//

import CoreGraphics

enum MapChromeLayout {

    // MARK: - What is stacked, in points (the sizes the views are drawn at)

    /// Between two controls, and between a control and the bar.
    static let gap: CGFloat = 8
    /// The centre-on-me button.
    static let locateButton: CGFloat = 44
    /// The two zoom buttons (32 each) and the 4 between them.
    static let zoomButtons: CGFloat = 68
    /// The zoom block's own padding above and below its buttons.
    static let zoomBlockPadding: CGFloat = 8
    /// The scale bar: its label, the 1 pt under it, and the row its line is drawn in.
    static let scaleBar: CGFloat = 24
    /// The row the 2D map's own logo and attribution button sit in: the height of what is drawn. The
    /// attribution button's frame is 44 pt with its glyph at the bottom, so the top 16 pt of that frame
    /// (nothing is drawn there) can lie under the position box; the glyph itself never does.
    static let ornamentRow: CGFloat = 28
    /// How far a control in a corner keeps from the bottom edge when the bar is not in its way.
    static let cornerMargin: CGFloat = 12

    // MARK: - Where they are across

    /// The left column's widest member is the scale bar's row (110 pt of bar and its ticks) and its margin.
    static let leftColumnWidth: CGFloat = 132
    /// The position box's distance from the right edge, and the widest it is drawn.
    static let rightMargin: CGFloat = 16
    static let cardMaxWidth: CGFloat = 300

    /// The widest the position box may be where the controls have `availableWidth` across (the
    /// window less its side safe areas): it stops short of the left column of controls, keeps its
    /// distance from the right edge, and is never wider than `cardMaxWidth` (on a phone held on
    /// its side it used to stretch across the whole screen).
    static func cardWidth(availableWidth: CGFloat) -> CGFloat {
        let available = PositionBoxStyle.maxWidth(screenWidth: Double(availableWidth),
                                                  leadingReserved: Double(leftColumnWidth + gap),
                                                  trailing: Double(rightMargin))
        return min(cardMaxWidth, CGFloat(available))
    }

    /// Where something that shares the position box's column and sits above it (the lasso selection
    /// pill) starts: on the box's top edge with a gap, or where the box would start while it is not
    /// shown. `cardHeight` is the box's drawn height (it grows with the text size), nil or 0 when hidden.
    static func bottomAbove(cardBottom: CGFloat, cardHeight: CGFloat?) -> CGFloat {
        guard let cardHeight, cardHeight > 0 else { return cardBottom }
        return cardBottom + cardHeight + gap
    }

    /// The bar's distance from the bottom edge when it has not been measured yet (a portrait phone's).
    static let unmeasuredBarClearance: CGFloat = 100

    /// Distances from the bottom edge of the screen to the BOTTOM of each thing, in points.
    struct Placement: Equatable {
        /// The 2D map's logo and its attribution button (nil: the globe has none).
        var logoBottom: CGFloat?
        var attributionBottom: CGFloat?
        var locateBottom: CGFloat
        /// The zoom block including its own padding (what `.padding(.bottom:)` is applied to).
        var zoomBlockBottom: CGFloat
        var scaleBarBottom: CGFloat
        var cardBottom: CGFloat
    }

    /// How far the bar (with its tip) reaches up from the bottom edge, or the unmeasured estimate.
    static func barClearance(bar: CGRect?, window: CGSize) -> CGFloat {
        guard let bar else { return unmeasuredBarClearance }
        return max(0, window.height - bar.minY)
    }

    /// - Parameters:
    ///   - bar: the bar's frame with its tip or edit header when shown, in window coordinates; nil
    ///     before it has been measured.
    ///   - window: the window's size.
    ///   - safeBottom: the bottom safe-area inset (the home indicator). The map's controls are laid
    ///     out from the bottom edge of the screen, so this only keeps a corner control off it.
    ///   - safeLeft, safeRight: the side safe-area insets. The controls are laid out inside them (a
    ///     phone held on its side has about 60 pt each side), so the columns start and end there.
    ///   - ornaments: true on the 2D map, whose own logo and attribution button need a row of their own.
    static func placement(bar: CGRect?, window: CGSize, safeBottom: CGFloat, safeLeft: CGFloat = 0,
                          safeRight: CGFloat = 0, ornaments: Bool) -> Placement {
        let clearance = barClearance(bar: bar, window: window)
        // A column clears the bar only when the bar is across from it: a phone held on its side has
        // its bar as a pill in the middle and the corners are free.
        let barX = bar.map { $0.minX...$0.maxX } ?? 0...window.width
        let leftX = safeLeft...(safeLeft + leftColumnWidth)
        let rightEdge = window.width - safeRight
        let rightX = (rightEdge - rightMargin - cardWidth(availableWidth: rightEdge - safeLeft))...rightEdge
        let corner = max(cornerMargin, safeBottom)
        let leftBase = barX.overlaps(leftX) ? clearance + gap : corner
        let rightBase = barX.overlaps(rightX) ? clearance + gap : corner

        let row: CGFloat = ornaments ? ornamentRow + gap : 0
        let locate = leftBase + row
        return Placement(
            logoBottom: ornaments ? leftBase : nil,
            attributionBottom: ornaments ? rightBase : nil,
            locateBottom: locate,
            zoomBlockBottom: locate + locateButton + gap - zoomBlockPadding,
            scaleBarBottom: locate + locateButton + gap + zoomButtons + gap,
            cardBottom: rightBase + row)
    }
}
