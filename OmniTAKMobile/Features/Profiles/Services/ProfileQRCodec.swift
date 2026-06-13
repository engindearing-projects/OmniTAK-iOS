//
//  ProfileQRCodec.swift
//  OmniTAKMobile
//
//  QR encode/decode for ConfigProfile.
//
//  Payload format: omnitak://profile?d=<base64url(gzip(JSON))>
//  Target: < ~2 KB so a standard QR scans reliably (single-block mode).
//  Uses Foundation Compression (zlib/gzip via NS_DATA_COMPRESSION or raw deflate).
//  Falls back to uncompressed base64url if the payload is already tiny.
//

import Foundation
import CoreImage
import UIKit

// MARK: - Errors

enum ProfileQRError: LocalizedError {
    case encodingFailed(String)
    case decodingFailed(String)
    case notAProfileURL
    case missingPayload
    case payloadTooLarge(Int)
    case decompressedPayloadTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let msg): return "Profile encoding failed: \(msg)"
        case .decodingFailed(let msg): return "Profile decoding failed: \(msg)"
        case .notAProfileURL: return "URL is not an omnitak://profile link"
        case .missingPayload: return "QR link is missing the profile payload"
        case .payloadTooLarge(let bytes): return "Profile payload is too large (\(bytes) bytes) for a reliable QR code"
        case .decompressedPayloadTooLarge(let bytes): return "Decompressed profile payload is too large (\(bytes) bytes)"
        }
    }
}

// MARK: - Codec

enum ProfileQRCodec {

    /// Maximum URL length we'll attempt to encode.
    /// QR version 40-L holds ~7 KB of alphanumeric, but scanning degrades
    /// above ~2 KB on typical phone cameras in bright field conditions.
    static let maxURLBytes = 2800

    // MARK: Encode

    /// Encode a ConfigProfile into an `omnitak://profile?d=...` URL string.
    static func encode(_ profile: ConfigProfile) throws -> String {
        let json = try JSONEncoder().encode(profile)
        let compressed = compress(json)
        let payload = base64URLEncode(compressed)
        let urlString = "omnitak://profile?d=\(payload)"

        let byteCount = urlString.utf8.count
        if byteCount > maxURLBytes {
            throw ProfileQRError.payloadTooLarge(byteCount)
        }
        return urlString
    }

    /// Decode an `omnitak://profile?d=...` URL string into a ConfigProfile.
    static func decode(urlString: String) throws -> ConfigProfile {
        guard let url = URL(string: urlString) else {
            throw ProfileQRError.decodingFailed("Not a valid URL")
        }
        return try decode(url: url)
    }

    /// Decode an `omnitak://profile?d=...` URL into a ConfigProfile.
    static func decode(url: URL) throws -> ConfigProfile {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""

        guard scheme == "omnitak", host == "profile" else {
            throw ProfileQRError.notAProfileURL
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dParam = components.queryItems?.first(where: { $0.name == "d" })?.value,
              !dParam.isEmpty else {
            throw ProfileQRError.missingPayload
        }

        let compressed = try base64URLDecode(dParam)
        let json: Data
        do {
            let decompressed = try decompress(compressed)
            // Guard against decompression bombs: cap at 64 KiB.
            // A realistic full profile is well under 2 KiB compressed; this is
            // a hard safety rail, not a QR-size limit.
            guard decompressed.count <= 65_536 else {
                throw ProfileQRError.decompressedPayloadTooLarge(decompressed.count)
            }
            json = decompressed
        } catch let qrErr as ProfileQRError {
            throw qrErr
        } catch {
            // Fallback: treat as raw (uncompressed) JSON for very small payloads
            json = compressed
        }

        do {
            return try JSONDecoder().decode(ConfigProfile.self, from: json)
        } catch {
            throw ProfileQRError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: QR Image Generation

    /// Generate a UIImage containing the QR code for a profile URL.
    /// Returns nil if CoreImage fails (e.g. in unit tests without a display).
    static func generateQRImage(for urlString: String, size: CGFloat = 300) -> UIImage? {
        // Use UTF-8 so non-ASCII team names (CJK, Arabic, etc.) encode correctly.
        // CIQRCodeGenerator accepts raw UTF-8 bytes; .isoLatin1 produces nil for
        // any character outside the Latin-1 range, resulting in a blank QR.
        guard let data = urlString.data(using: .utf8) else { return nil }

        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel") // ~15% redundancy

        guard let outputImage = filter.outputImage else { return nil }

        // Scale up — raw QR output is tiny
        let scale = size / outputImage.extent.width
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Private helpers

    /// Compress data using zlib deflate (via NSData bridge available since iOS 9).
    /// Uses NSData's `compressed(using:)` available from iOS 13+.
    private static func compress(_ data: Data) -> Data {
        if #available(iOS 13.0, *) {
            return (try? (data as NSData).compressed(using: .zlib) as Data) ?? data
        }
        return data
    }

    /// Decompress zlib deflate data.
    private static func decompress(_ data: Data) throws -> Data {
        if #available(iOS 13.0, *) {
            do {
                return try (data as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw ProfileQRError.decodingFailed("Decompression failed: \(error.localizedDescription)")
            }
        }
        // No compression available on older OS; assume uncompressed
        return data
    }

    /// URL-safe base64 encoding (RFC 4648 §5): replaces + with -, / with _, strips =.
    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// URL-safe base64 decoding — inverse of base64URLEncode.
    static func base64URLDecode(_ string: String) throws -> Data {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = padded.count % 4
        if rem != 0 { padded += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: padded) else {
            throw ProfileQRError.decodingFailed("Invalid base64url string")
        }
        return data
    }
}
