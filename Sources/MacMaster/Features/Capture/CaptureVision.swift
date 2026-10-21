import Foundation
import Vision
import CoreGraphics

/// Vision requests for Capture. Everything here is synchronous and `nonisolated`: call from a background task.
enum CaptureVision {
    struct Output: Sendable {
        var text: String = ""
        var codes: [Code] = []
    }
    struct Code: Sendable { var payload: String; var symbology: String }

    /// Recognizes text (and optionally barcodes) in one handler pass.
    nonisolated static func analyze(_ image: CGImage, text wantText: Bool, codes wantCodes: Bool,
                                    preferredLanguages: Bool, keepLineBreaks: Bool) -> Output {
        var requests: [VNRequest] = []
        let textReq = VNRecognizeTextRequest()
        if wantText {
            configure(textReq, preferredLanguages: preferredLanguages)
            requests.append(textReq)
        }
        let codeReq = VNDetectBarcodesRequest()
        if wantCodes { requests.append(codeReq) }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform(requests) } catch { return Output() }

        var out = Output()
        if wantText {
            let lines = (textReq.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            out.text = join(lines, keepLineBreaks: keepLineBreaks)
        }
        if wantCodes {
            var seen = Set<String>()
            for o in codeReq.results ?? [] {
                guard let p = o.payloadStringValue, !p.isEmpty, seen.insert(p).inserted else { continue }
                out.codes.append(Code(payload: p, symbology: symbologyName(o.symbology)))
            }
        }
        return out
    }

    nonisolated static func configure(_ req: VNRecognizeTextRequest, preferredLanguages: Bool) {
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        if preferredLanguages {
            let langs = matchLanguages(Locale.preferredLanguages, supported: supported)
            if !langs.isEmpty {
                req.recognitionLanguages = langs
                req.automaticallyDetectsLanguage = false
                return
            }
        }
        req.automaticallyDetectsLanguage = true
    }

    /// Maps system language tags like "en-GB" or "zh-Hans-US" onto the codes Vision supports.
    nonisolated static func matchLanguages(_ preferred: [String], supported: [String]) -> [String] {
        var out: [String] = []
        for tag in preferred {
            let parts = tag.split(separator: "-").map(String.init)
            guard let lang = parts.first else { continue }
            var candidates = [tag]
            if parts.count >= 2 { candidates.append(parts.prefix(2).joined(separator: "-")) }
            candidates.append(lang)
            var match = candidates.first(where: { supported.contains($0) })
            if match == nil { match = supported.first(where: { $0.hasPrefix(lang + "-") }) }
            if let m = match, !out.contains(m) { out.append(m) }
        }
        return out
    }

    /// Joins recognized lines. Without line breaks the lines become one paragraph and hyphenated ends are rejoined.
    nonisolated static func join(_ lines: [String], keepLineBreaks: Bool) -> String {
        let clean = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if keepLineBreaks { return clean.joined(separator: "\n") }
        var out = ""
        for line in clean {
            if out.isEmpty { out = line; continue }
            if out.hasSuffix("-"), let f = line.first, f.isLowercase {
                out.removeLast()
                out += line
            } else {
                out += " " + line
            }
        }
        return out
    }

    nonisolated static func symbologyName(_ s: VNBarcodeSymbology) -> String {
        switch s {
        case .qr: return "QR code"
        case .microQR: return "Micro QR"
        case .aztec: return "Aztec"
        case .pdf417: return "PDF417"
        case .dataMatrix: return "Data Matrix"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .upce: return "UPC-E"
        case .itf14: return "ITF-14"
        default: return "Barcode"
        }
    }
}
