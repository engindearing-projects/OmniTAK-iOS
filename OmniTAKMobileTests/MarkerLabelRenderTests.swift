//
//  MarkerLabelRenderTests.swift
//  OmniTAKMobileTests
//
//  #132 — 2D contact callsigns are a Mapbox text field on the annotation, not
//  pixels baked into the marker bitmap (which came from an off-window
//  `drawHierarchy` snapshot and rendered "???" on some iPhones). There were no
//  snapshot tests, so these stay simple: a pixel check that the symbol bitmap is
//  just the symbol, and checks that the annotation's text-field options carry the
//  callsign verbatim.
//

import XCTest
import UIKit
import CoreLocation
import MapboxMaps
@testable import OmniTAK

final class MarkerLabelRenderTests: XCTestCase {

    // MARK: - Helpers

    /// RGBA8 (premultiplied) pixels of a UIImage, row 0 = top.
    private struct Bitmap {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]), Int(rgba[i + 3]))
        }

        /// Bounding box of pixels whose alpha is above `threshold`.
        func bounds(alphaAbove threshold: Int) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where pixel(x, y).a > threshold {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return maxX < 0 ? nil : (minX, minY, maxX, maxY)
        }

        /// Mean color of pixels whose alpha is above `threshold`, un-premultiplied.
        func meanColor(alphaAbove threshold: Int) -> (r: Double, g: Double, b: Double)? {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let p = pixel(x, y)
                    guard p.a > threshold else { continue }
                    let a = Double(p.a) / 255.0
                    r += Double(p.r) / a; g += Double(p.g) / a; b += Double(p.b) / a
                    n += 1
                }
            }
            return n == 0 ? nil : (r / n, g / n, b / n)
        }
    }

    private func bitmap(of image: UIImage) throws -> Bitmap {
        let cg = try XCTUnwrap(image.cgImage, "symbol image has no CGImage")
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drew, "could not create a bitmap context")
        return Bitmap(width: w, height: h, rgba: data)
    }

    private func marker(type: String = "a-f-G-U-C",
                        callsign: String,
                        uid: String = "uid-1",
                        receivedAt: Date? = nil) -> CoTMarker {
        CoTMarker(
            uid: uid,
            coordinate: CLLocationCoordinate2D(latitude: 47.66, longitude: -117.43),
            type: type,
            callsign: callsign,
            team: "Cyan",
            receivedAt: receivedAt
        )
    }

    private let frame = ContactMarkerRender.symbolSize
    private let margin = ContactMarkerRender.symbolMargin

    // MARK: - Symbol bitmap: symbol only

    func testSymbolBitmapIsJustTheSymbolSize() throws {
        for type in ["a-f-G-U-C", "a-h-G-U-C", "a-n-G-U-C", "a-u-G"] {
            let img = ContactMarkerRender.symbolImage(cotType: type, scale: 1)
            let side = Int(frame + margin * 2)
            let bmp = try bitmap(of: img)
            XCTAssertEqual(bmp.width, side, "\(type): width")
            XCTAssertEqual(bmp.height, side, "\(type): height")
            // The old baked bitmap was 80x56 (symbol on top, callsign pill under
            // it). Anything near that size means a label strip came back.
            XCTAssertLessThanOrEqual(bmp.width, 40, "\(type): too wide, label strip?")
            XCTAssertLessThanOrEqual(bmp.height, 40, "\(type): too tall, label strip?")
        }
    }

    func testSymbolContentStaysInsideTheFrameAndIsCentered() throws {
        for type in ["a-f-G-U-C", "a-h-G-U-C", "a-n-G-U-C", "a-u-G"] {
            let bmp = try bitmap(of: ContactMarkerRender.symbolImage(cotType: type, scale: 1))
            // Everything reasonably opaque (frame, outline, glyph; not the faint
            // glow) must sit within the frame rect plus half the stroke.
            let b = try XCTUnwrap(bmp.bounds(alphaAbove: 128), "\(type): nothing drawn")
            let lo = Int(margin) - 3, hi = Int(margin + frame) + 2
            XCTAssertGreaterThanOrEqual(b.minX, lo, "\(type): content left of the frame")
            XCTAssertGreaterThanOrEqual(b.minY, lo, "\(type): content above the frame")
            XCTAssertLessThanOrEqual(b.maxX, hi, "\(type): content right of the frame (a callsign pill is wider than the frame)")
            XCTAssertLessThanOrEqual(b.maxY, hi, "\(type): content below the frame (a callsign pill sits under it)")
            // Centered on the canvas, so `iconAnchor = .center` lands on the coordinate.
            let cx = Double(b.minX + b.maxX) / 2, cy = Double(b.minY + b.maxY) / 2
            let mid = Double(bmp.width - 1) / 2
            XCTAssertEqual(cx, mid, accuracy: 1.5, "\(type): not centered horizontally")
            XCTAssertEqual(cy, mid, accuracy: 1.5, "\(type): not centered vertically")
        }
    }

    func testSymbolCornersAreTransparent() throws {
        for type in ["a-f-G-U-C", "a-h-G-U-C", "a-n-G-U-C", "a-u-G"] {
            let bmp = try bitmap(of: ContactMarkerRender.symbolImage(cotType: type, scale: 1))
            let last = bmp.width - 1
            for (x, y) in [(0, 0), (last, 0), (0, last), (last, last)] {
                XCTAssertLessThanOrEqual(bmp.pixel(x, y).a, 6, "\(type): corner (\(x),\(y)) should be clear")
            }
        }
    }

    func testSymbolIsDrawnInTheAffiliationColor() throws {
        // (type, dominant channel check on the opaque outline pixels)
        let friendly = try XCTUnwrap(try bitmap(of: ContactMarkerRender.symbolImage(cotType: "a-f-G-U-C", scale: 1)).meanColor(alphaAbove: 200))
        XCTAssertGreaterThan(friendly.b, friendly.r + 100, "friendly reads blue")

        let hostile = try XCTUnwrap(try bitmap(of: ContactMarkerRender.symbolImage(cotType: "a-h-G-U-C", scale: 1)).meanColor(alphaAbove: 200))
        XCTAssertGreaterThan(hostile.r, hostile.b + 100, "hostile reads red")

        let neutral = try XCTUnwrap(try bitmap(of: ContactMarkerRender.symbolImage(cotType: "a-n-G-U-C", scale: 1)).meanColor(alphaAbove: 200))
        XCTAssertGreaterThan(neutral.g, neutral.r + 100, "neutral reads green")

        let unknown = try XCTUnwrap(try bitmap(of: ContactMarkerRender.symbolImage(cotType: "a-u-G", scale: 1)).meanColor(alphaAbove: 200))
        XCTAssertGreaterThan(unknown.r, unknown.b + 100, "unknown reads yellow (red channel)")
        XCTAssertGreaterThan(unknown.g, unknown.b + 100, "unknown reads yellow (green channel)")
    }

    func testAffiliationsRenderDistinctShapes() throws {
        var seen = Set<Data>()
        for type in ["a-f-G-U-C", "a-h-G-U-C", "a-n-G-U-C", "a-u-G"] {
            let png = try XCTUnwrap(ContactMarkerRender.symbolImage(cotType: type, scale: 1).pngData())
            seen.insert(png)
        }
        XCTAssertEqual(seen.count, 4, "each affiliation draws its own frame")
    }

    func testGenericUnitDrawsAPlainFrameWithoutAGlyph() throws {
        // Colors in the middle of the frame, well inside the outline.
        func centerColors(_ type: String) throws -> Set<[Int]> {
            let bmp = try bitmap(of: ContactMarkerRender.symbolImage(cotType: type, scale: 1))
            let c = Int(margin + frame / 2)
            var colors = Set<[Int]>()
            for y in (c - 3)...(c + 3) {
                for x in (c - 3)...(c + 3) {
                    let p = bmp.pixel(x, y)
                    colors.insert([p.r, p.g, p.b, p.a])
                }
            }
            return colors
        }
        // "a-f-G-U-C" is what a TAK client reports for itself by default. It
        // carries no function code, so the frame stays plain: fill only, no
        // "?" placeholder sitting where a callsign-like mark would be.
        XCTAssertEqual(try centerColors("a-f-G-U-C").count, 1, "default position report: plain frame")
        XCTAssertEqual(try centerColors("a-h-G").count, 1, "no function code at all: plain frame")
        // A unit with a function code keeps its glyph.
        XCTAssertGreaterThan(try centerColors("a-f-G-U-C-I").count, 1, "infantry draws its glyph")
    }

    // MARK: - Annotation: text field carries the callsign

    func testTextFieldCarriesTheCallsign() {
        let m = marker(callsign: "ALPHA-1")
        let ann = ContactMarkerRender.annotation(for: m, image: ContactMarkerRender.symbolImage(cotType: m.type))
        XCTAssertEqual(ann.textField, "ALPHA-1")
        XCTAssertEqual(ann.textAnchor, .top)
        XCTAssertEqual(ann.textOffset, [0, ContactMarkerRender.labelOffsetEm])
        XCTAssertEqual(ann.textSize, ContactMarkerRender.labelTextSize)
        XCTAssertEqual(ann.textColor, StyleColor(.white))
        XCTAssertEqual(ann.textHaloColor, StyleColor(.black))
        XCTAssertEqual(ann.id, "cot-uid-1")
    }

    func testTextFieldIsVerbatimForAnyScript() {
        // The field report was "???" for every name; none of these may be
        // transliterated, folded, escaped, or dropped on the way to Mapbox.
        let callsigns = ["ALPHA-1", "Ünïcode-Ω", "鷹眼-3", "Позывной-7", "bravo 🛰 2", "a&b <c> {d}", "O'Neil \"Doc\""]
        for cs in callsigns {
            let m = marker(callsign: cs)
            let ann = ContactMarkerRender.annotation(for: m, image: ContactMarkerRender.symbolImage(cotType: m.type))
            XCTAssertEqual(ann.textField, cs, "callsign must reach the text field unchanged")
        }
    }

    func testBlankCallsignHasNoTextField() {
        let m = marker(callsign: "   ")
        let ann = ContactMarkerRender.annotation(for: m, image: ContactMarkerRender.symbolImage(cotType: m.type))
        XCTAssertNil(ann.textField)
    }

    func testSymbolIsCenteredOnTheCoordinate() {
        let m = marker(callsign: "ALPHA-1")
        let ann = ContactMarkerRender.annotation(for: m, image: ContactMarkerRender.symbolImage(cotType: m.type))
        XCTAssertEqual(ann.iconAnchor, .center)
        XCTAssertEqual(ann.point.coordinates.latitude, m.coordinate.latitude, accuracy: 1e-9)
        XCTAssertEqual(ann.point.coordinates.longitude, m.coordinate.longitude, accuracy: 1e-9)
    }

    // MARK: - Image key / cache: callsign-free

    func testImageKeyHasNoCallsign() {
        let a = marker(callsign: "ALPHA-1", uid: "u1")
        let b = marker(callsign: "BRAVO-2", uid: "u2")
        let annA = ContactMarkerRender.annotation(for: a, image: ContactMarkerRender.symbolImage(cotType: a.type))
        let annB = ContactMarkerRender.annotation(for: b, image: ContactMarkerRender.symbolImage(cotType: b.type))
        let nameA = annA.image?.name ?? ""
        let nameB = annB.image?.name ?? ""
        XCTAssertFalse(nameA.isEmpty)
        XCTAssertEqual(nameA, nameB, "same type/iconset/color share one sprite whatever the callsign")
        XCTAssertFalse(nameA.contains("ALPHA-1"))
        // The text differs, the sprite does not.
        XCTAssertNotEqual(annA.textField, annB.textField)
        // Same bytes too: nothing about the callsign is in the bitmap.
        XCTAssertEqual(annA.image?.image.pngData(), annB.image?.image.pngData())
    }

    func testImageKeyStillSeparatesIconSources() {
        let base = ContactMarkerRender.imageKey(cotType: "a-f-G", iconsetPath: nil, argb: nil)
        XCTAssertNotEqual(base, ContactMarkerRender.imageKey(cotType: "a-h-G", iconsetPath: nil, argb: nil))
        XCTAssertNotEqual(base, ContactMarkerRender.imageKey(cotType: "a-f-G", iconsetPath: "COT_MAPPING_SPOTMAP/red", argb: nil))
        XCTAssertNotEqual(base, ContactMarkerRender.imageKey(cotType: "a-f-G", iconsetPath: nil, argb: -65536))
        // New scheme, so it can never collide with a stale `cot|type|...|callsign` entry.
        XCTAssertFalse(base.hasPrefix("cot|"))
    }

    // MARK: - Staleness overlay (#178) rides the same text field

    func testStalenessOverlayAddsAgeLineAndFadesTheLabelWithTheIcon() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let m = marker(callsign: "ALPHA-1", receivedAt: now.addingTimeInterval(-120))
        let img = ContactMarkerRender.symbolImage(cotType: m.type)

        let off = ContactMarkerRender.annotation(for: m, image: img, stalenessOverlay: false, now: now)
        XCTAssertEqual(off.textField, "ALPHA-1", "overlay off: callsign only")
        XCTAssertNil(off.iconOpacity)
        XCTAssertNil(off.textOpacity)

        let on = ContactMarkerRender.annotation(for: m, image: img, stalenessOverlay: true, now: now)
        let age = try XCTUnwrap(CoTAge.shortLabel(receivedAt: m.receivedAt, now: now))
        XCTAssertEqual(on.textField, "ALPHA-1\n\(age)")
        let alpha = CoTAge.alpha(receivedAt: try XCTUnwrap(m.receivedAt), now: now)
        XCTAssertEqual(on.iconOpacity, alpha)
        XCTAssertEqual(on.textOpacity, alpha)
    }

    func testStalenessOverlayWithoutReceiveTimeKeepsPlainCallsign() {
        let m = marker(callsign: "ALPHA-1", receivedAt: nil)
        let ann = ContactMarkerRender.annotation(for: m, image: ContactMarkerRender.symbolImage(cotType: m.type), stalenessOverlay: true)
        XCTAssertEqual(ann.textField, "ALPHA-1")
        XCTAssertNil(ann.iconOpacity)
    }

    func testLabelTextCombinations() {
        XCTAssertEqual(ContactMarkerRender.labelText(callsign: "A"), "A")
        XCTAssertEqual(ContactMarkerRender.labelText(callsign: "  A  "), "A")
        XCTAssertEqual(ContactMarkerRender.labelText(callsign: "A", ageLabel: "3m"), "A\n3m")
        XCTAssertEqual(ContactMarkerRender.labelText(callsign: "", ageLabel: "3m"), "3m")
        XCTAssertNil(ContactMarkerRender.labelText(callsign: ""))
    }
}
