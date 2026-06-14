//
//  MarkerCoTGenerator.swift
//  OmniTAKMobile
//
//  Generates CoT XML messages for point markers
//

import Foundation
import CoreLocation

// MARK: - Marker CoT Generator

/// Generates TAK-compatible CoT XML for point markers
class MarkerCoTGenerator {

    /// Generate CoT XML for a point marker
    static func generateCoT(for marker: PointMarker, staleTime: TimeInterval = 3600) -> String {
        // Icon + color (issue #75 — the standard TAK icon suite). Each pack
        // emits its canonical `usericon iconsetpath` so the marker renders as
        // the exact icon the operator picked on ATAK / iTAK / TAK Server:
        //   • Spot Map → `COT_MAPPING_SPOTMAP/{color}` + the swatch color
        //   • Markers  → `COT_MAPPING_2525C/{2525type}` (color follows affiliation)
        //   • Google   → `{googleUID}/{token}.png`
        // Markers/Spots that carry no explicit pack fall back to the
        // affiliation-keyed spot-map path the app has always sent.
        let iconsetPath: String
        let argbColor: Int
        if let takIcon = marker.takIcon {
            iconsetPath = takIcon.iconsetPath
            argbColor = hexToARGB(takIcon.argbHex)
        } else if let markersIcon = marker.markersIcon {
            iconsetPath = markersIcon.iconsetPath
            argbColor = hexToARGB(marker.affiliation.hexColor)
        } else if let googleIcon = marker.googleIcon {
            iconsetPath = googleIcon.iconsetPath
            argbColor = hexToARGB(marker.affiliation.hexColor)
        } else {
            iconsetPath = "COT_MAPPING_SPOTMAP/\(marker.affiliation.rawValue.lowercased())_point"
            argbColor = hexToARGB(marker.affiliation.hexColor)
        }

        var detail = """
                <contact callsign="\(marker.name.xmlEscaped)"/>
                <usericon iconsetpath="\(iconsetPath)"/>
                <color argb="\(argbColor)"/>
                <affiliation value="\(marker.affiliation.rawValue)"/>
        """

        // Add remarks
        if let remarks = marker.remarks, !remarks.isEmpty {
            detail += "\n        <remarks>\(remarks.xmlEscaped)</remarks>"
        }

        // Add SALUTE report if present
        if let salute = marker.saluteReport {
            detail += generateSALUTEElement(salute)
        }

        // Add marker metadata
        detail += """

                <precisionlocation altsrc="GPS" geopointsrc="User"/>
                <status readiness="true"/>
                <_marker_>\(marker.affiliation.shortCode)</_marker_>
                <takv device="iPhone" platform="OmniTAK" os="iOS" version="\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")"/>
        """

        return CoTXMLBuilder.buildEvent(
            uid: marker.uid,
            type: marker.cotType,
            how: "h-g-i-g-o",
            staleAfter: staleTime,
            coordinate: marker.coordinate,
            hae: marker.altitude ?? 0.0,
            ce: 10.0,
            le: 10.0,
            detail: detail
        )
    }

    /// Generate SALUTE report as CoT XML elements
    private static func generateSALUTEElement(_ report: SALUTEReport) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "ddHHmm'Z' MMM yy"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let timeStr = dateFormatter.string(from: report.time).uppercased()

        let saluteXML = """

                <__salute__>
                    <size>\(report.size.xmlEscaped)</size>
                    <activity>\(report.activity.xmlEscaped)</activity>
                    <location>\(report.location.xmlEscaped)</location>
                    <unit>\(report.unit.xmlEscaped)</unit>
                    <time>\(timeStr)</time>
                    <equipment>\(report.equipment.xmlEscaped)</equipment>
                </__salute__>
                <remarks>SALUTE: \(report.summary.xmlEscaped)</remarks>
        """

        return saluteXML
    }

    /// Generate a hostile point marker CoT
    static func generateHostileMarker(
        uid: String,
        name: String,
        coordinate: CLLocationCoordinate2D,
        altitude: Double = 0,
        remarks: String? = nil,
        staleTime: TimeInterval = 3600
    ) -> String {
        let marker = PointMarker(
            id: UUID(),
            name: name,
            affiliation: .hostile,
            coordinate: coordinate,
            altitude: altitude,
            remarks: remarks
        )

        return generateCoT(for: marker, staleTime: staleTime)
    }

    /// Generate a friendly point marker CoT
    static func generateFriendlyMarker(
        uid: String,
        name: String,
        coordinate: CLLocationCoordinate2D,
        altitude: Double = 0,
        remarks: String? = nil,
        staleTime: TimeInterval = 3600
    ) -> String {
        let marker = PointMarker(
            id: UUID(),
            name: name,
            affiliation: .friendly,
            coordinate: coordinate,
            altitude: altitude,
            remarks: remarks
        )

        return generateCoT(for: marker, staleTime: staleTime)
    }

    /// Generate spot report CoT (simplified SALUTE)
    static func generateSpotReport(
        uid: String,
        name: String,
        affiliation: MarkerAffiliation,
        coordinate: CLLocationCoordinate2D,
        size: String,
        activity: String,
        unit: String,
        equipment: String,
        staleTime: TimeInterval = 3600
    ) -> String {
        let report = SALUTEReport(
            size: size,
            activity: activity,
            location: formatMGRS(coordinate),
            unit: unit,
            time: Date(),
            equipment: equipment
        )

        let marker = PointMarker(
            id: UUID(),
            name: name,
            affiliation: affiliation,
            coordinate: coordinate,
            saluteReport: report
        )

        return generateCoT(for: marker, staleTime: staleTime)
    }

    /// Generate batch CoT messages for multiple markers
    static func generateBatchCoT(markers: [PointMarker], staleTime: TimeInterval = 3600) -> [String] {
        return markers.map { generateCoT(for: $0, staleTime: staleTime) }
    }

    // MARK: - Helper Methods

    /// Convert hex color string (AARRGGBB) to signed 32-bit ARGB integer.
    /// Example: "FF00FFFF" (cyan) -> -16711681, "FFFF0000" (red) -> -65536.
    ///
    /// TAK `<color argb>` values are signed 32-bit ints — that's what ATAK
    /// writes and what its `Integer.parseInt` reader expects. The opaque-alpha
    /// values (0xFFxxxxxx) overflow `Int32.max`, so we MUST reinterpret the
    /// 32-bit pattern as signed (Int32 → Int) rather than widening the unsigned
    /// value (which produced e.g. 4294901760 — a number ATAK can't parse).
    private static func hexToARGB(_ hexString: String) -> Int {
        // Remove any # prefix if present
        let hex = hexString.replacingOccurrences(of: "#", with: "")

        // Parse as UInt32 first
        guard let hexValue = UInt32(hex, radix: 16) else {
            return -1  // Default to white if parsing fails
        }

        // Reinterpret the 32-bit pattern as a signed Int32, then widen. This
        // yields the negative values TAK uses for opaque colors.
        return Int(Int32(bitPattern: hexValue))
    }

    /// Format coordinate as MGRS-like string
    private static func formatMGRS(_ coordinate: CLLocationCoordinate2D) -> String {
        let lat = abs(coordinate.latitude)
        let lon = abs(coordinate.longitude)
        let latDeg = Int(lat)
        let lonDeg = Int(lon)
        let latMin = Int((lat - Double(latDeg)) * 60)
        let lonMin = Int((lon - Double(lonDeg)) * 60)
        let latSec = Int(((lat - Double(latDeg)) * 60 - Double(latMin)) * 60)
        let lonSec = Int(((lon - Double(lonDeg)) * 60 - Double(lonMin)) * 60)

        let latDir = coordinate.latitude >= 0 ? "N" : "S"
        let lonDir = coordinate.longitude >= 0 ? "E" : "W"

        return "\(latDeg)°\(latMin)'\(latSec)\"\(latDir) \(lonDeg)°\(lonMin)'\(lonSec)\"\(lonDir)"
    }

    /// Attempt to recognize a FEMA / IC icon from a CoT type string.
    /// Used by future inbound-CoT-to-PointMarker code paths so an incoming
    /// marker that matches one of our MVP type codes (issue #13) renders
    /// with the FEMA icon instead of falling back to MIL-2525 affiliation
    /// rendering. See `FemaIconSet.swift` for the speculative-code caveat.
    static func parseFemaIcon(from cotType: String) -> FemaIcon? {
        return FemaIcon.from(cotType: cotType)
    }

    /// Parse CoT type to determine affiliation
    static func parseAffiliation(from cotType: String) -> MarkerAffiliation {
        let components = cotType.split(separator: "-")
        guard components.count >= 2 else { return .unknown }

        let affiliationCode = String(components[1]).lowercased()
        switch affiliationCode {
        case "f": return .friendly
        case "h": return .hostile
        case "n": return .neutral
        case "u": return .unknown
        default: return .unknown
        }
    }

    /// Validate CoT XML structure
    static func validateCoT(_ xml: String) -> Bool {
        // Basic validation
        return xml.contains("<?xml") &&
               xml.contains("<event") &&
               xml.contains("</event>") &&
               xml.contains("<point") &&
               xml.contains("uid=") &&
               xml.contains("type=")
    }
}

// MARK: - CoT Type Constants

extension MarkerCoTGenerator {

    /// Standard CoT types for different marker affiliations
    struct CoTTypes {
        // Ground units
        static let friendlyGround = "a-f-G-U-C"      // Friendly Ground Unit Combat
        static let hostileGround = "a-h-G-U-C"       // Hostile Ground Unit Combat
        static let neutralGround = "a-n-G"           // Neutral Ground
        static let unknownGround = "a-u-G"           // Unknown Ground

        // Specific unit types
        static let friendlyInfantry = "a-f-G-U-C-I"  // Friendly Infantry
        static let hostileInfantry = "a-h-G-U-C-I"   // Hostile Infantry
        static let friendlyArmor = "a-f-G-U-C-A"     // Friendly Armor
        static let hostileArmor = "a-h-G-U-C-A"      // Hostile Armor

        // Point markers
        static let spotReport = "b-m-p-w"            // Waypoint/Spot
        static let hostileSpot = "a-h-G-E-S"         // Hostile Equipment/Sensor

        // Emergency
        static let emergency = "b-r-f-h-c"           // Emergency/Alert
    }

    /// How values for CoT events
    struct HowValues {
        static let gpsManual = "h-g-i-g-o"           // GPS + Manual input
        static let gpsAuto = "m-g"                   // Machine generated from GPS
        static let manual = "h-e"                    // Human estimated
        static let calculated = "m-p"                // Machine calculated/predicted
    }
}
