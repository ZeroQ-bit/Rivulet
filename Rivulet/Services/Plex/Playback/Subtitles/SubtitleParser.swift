//
//  SubtitleParser.swift
//  Rivulet
//
//  Parsers for SRT and WebVTT subtitle formats.
//

import Foundation

// MARK: - Parser Protocol

protocol SubtitleParser {
    func parse(_ content: String) throws -> SubtitleTrack
}

enum SubtitleParseError: Error, LocalizedError {
    case invalidFormat(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "Invalid subtitle format: \(msg)"
        case .emptyContent: return "Subtitle file is empty"
        }
    }
}

// MARK: - SRT Parser

/// Parser for SubRip (.srt) subtitle files
/// Format:
/// ```
/// 1
/// 00:00:01,000 --> 00:00:04,000
/// First subtitle line
/// Second line (optional)
///
/// 2
/// 00:00:05,000 --> 00:00:08,000
/// Next subtitle
/// ```
struct SRTParser: SubtitleParser {

    func parse(_ content: String) throws -> SubtitleTrack {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw SubtitleParseError.emptyContent
        }

        var cues: [SubtitleCue] = []

        // Split by double newlines (cue separator)
        // Handle both \r\n and \n line endings
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalizedContent.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            guard lines.count >= 2 else { continue }

            // Find the timing line (contains "-->")
            var timingLineIndex = 0
            for (index, line) in lines.enumerated() {
                if line.contains("-->") {
                    timingLineIndex = index
                    break
                }
            }

            let timingLine = lines[timingLineIndex]
            guard let (start, end) = parseTimingLine(timingLine) else { continue }

            // Text is everything after the timing line
            let textLines = Array(lines[(timingLineIndex + 1)...])
            let text = textLines.joined(separator: "\n")

            guard !text.isEmpty else { continue }

            // Strip basic HTML-like tags (SRT sometimes has <i>, <b>, etc.)
            let cleanText = stripHTMLTags(text)

            cues.append(SubtitleCue(
                id: cues.count,
                startTime: start,
                endTime: end,
                text: cleanText
            ))
        }

        return SubtitleTrack(cues: cues.sorted { $0.startTime < $1.startTime })
    }

    /// Parse SRT timing line: "00:00:01,000 --> 00:00:04,000"
    private func parseTimingLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
            // Remove position metadata if present (e.g., "00:00:04,000 X1:0 Y1:0")
            .components(separatedBy: " ").first ?? ""

        guard let start = parseSRTTimestamp(startStr),
              let end = parseSRTTimestamp(endStr) else {
            return nil
        }

        return (start, end)
    }

    /// Parse SRT timestamp: "00:00:01,000" or "00:01,000"
    private func parseSRTTimestamp(_ timestamp: String) -> TimeInterval? {
        // Handle both HH:MM:SS,mmm and MM:SS,mmm formats
        let cleaned = timestamp.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")

        switch parts.count {
        case 3:
            // HH:MM:SS.mmm
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            // MM:SS.mmm
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }

    private func stripHTMLTags(_ text: String) -> String {
        // Remove common HTML tags: <i>, </i>, <b>, </b>, <u>, </u>, <font...>, </font>
        var result = text
        let tagPattern = #"<[^>]+>"#
        result = result.replacingOccurrences(of: tagPattern, with: "", options: .regularExpression)
        // Decode common HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        return result
    }
}

// MARK: - WebVTT Parser

/// Parser for WebVTT (.vtt) subtitle files
/// Format:
/// ```
/// WEBVTT
///
/// 00:00:01.000 --> 00:00:04.000
/// First subtitle line
///
/// NOTE This is a comment
///
/// 00:00:05.000 --> 00:00:08.000
/// Next subtitle
/// ```
struct VTTParser: SubtitleParser {

    func parse(_ content: String) throws -> SubtitleTrack {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw SubtitleParseError.emptyContent
        }

        // Normalize line endings
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")

        // VTT must start with "WEBVTT" (with optional BOM)
        let lines = normalizedContent.components(separatedBy: "\n")
        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") else {
            throw SubtitleParseError.invalidFormat("Missing WEBVTT header")
        }

        var cues: [SubtitleCue] = []
        var currentIndex = 1  // Skip WEBVTT line

        while currentIndex < lines.count {
            // Skip empty lines and metadata blocks
            let line = lines[currentIndex].trimmingCharacters(in: .whitespaces)
            currentIndex += 1

            if line.isEmpty || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                // Skip until next empty line for multi-line metadata
                if line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                    while currentIndex < lines.count && !lines[currentIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                        currentIndex += 1
                    }
                }
                continue
            }

            // Check if this is a timing line
            var timingLine = line
            if !line.contains("-->") {
                // This might be a cue identifier, next line should be timing
                guard currentIndex < lines.count else { continue }
                timingLine = lines[currentIndex].trimmingCharacters(in: .whitespaces)
                currentIndex += 1
            }

            guard timingLine.contains("-->"),
                  let (start, end) = parseTimingLine(timingLine) else {
                continue
            }

            // Collect text lines until empty line
            var textLines: [String] = []
            while currentIndex < lines.count {
                let textLine = lines[currentIndex]
                if textLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    currentIndex += 1
                    break
                }
                textLines.append(textLine)
                currentIndex += 1
            }

            let text = textLines.joined(separator: "\n")
            guard !text.isEmpty else { continue }

            // Strip VTT formatting tags
            let cleanText = stripVTTTags(text)

            cues.append(SubtitleCue(
                id: cues.count,
                startTime: start,
                endTime: end,
                text: cleanText
            ))
        }

        return SubtitleTrack(cues: cues.sorted { $0.startTime < $1.startTime })
    }

    /// Parse VTT timing line: "00:00:01.000 --> 00:00:04.000" with optional settings
    private func parseTimingLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        // End timestamp might have cue settings appended
        let endPart = parts[1].trimmingCharacters(in: .whitespaces)
        let endStr = endPart.components(separatedBy: " ").first ?? endPart

        guard let start = parseVTTTimestamp(startStr),
              let end = parseVTTTimestamp(endStr) else {
            return nil
        }

        return (start, end)
    }

    /// Parse VTT timestamp: "00:00:01.000" or "00:01.000"
    private func parseVTTTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.components(separatedBy: ":")

        switch parts.count {
        case 3:
            // HH:MM:SS.mmm
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            // MM:SS.mmm
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }

    private func stripVTTTags(_ text: String) -> String {
        var result = text
        // Remove VTT voice tags: <v Speaker>
        result = result.replacingOccurrences(of: #"<v[^>]*>"#, with: "", options: .regularExpression)
        // Remove other tags: <c>, <i>, <b>, <u>, <ruby>, <rt>, <lang>
        result = result.replacingOccurrences(of: #"</?[a-z][^>]*>"#, with: "", options: .regularExpression)
        // Remove timestamps within cue: <00:00:01.000>
        result = result.replacingOccurrences(of: #"<\d{2}:\d{2}[:\.\d]*>"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Parser Factory

enum SubtitleFormat {
    case srt
    case vtt
    case unknown

    init(from codec: String?) {
        guard let codec = codec?.lowercased() else {
            self = .unknown
            return
        }

        switch codec {
        case "srt", "subrip":
            self = .srt
        case "vtt", "webvtt":
            self = .vtt
        default:
            self = .unknown
        }
    }

    init(fromURL url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "srt":
            self = .srt
        case "vtt":
            self = .vtt
        default:
            self = .unknown
        }
    }

    var parser: SubtitleParser? {
        switch self {
        case .srt: return SRTParser()
        case .vtt: return VTTParser()
        case .unknown: return nil
        }
    }
}
