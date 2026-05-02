//
//  PlexOnDemandSubtitleService.swift
//  Rivulet
//
//  Searches and attaches Plex on-demand subtitles for the active item.
//

import Foundation

actor PlexOnDemandSubtitleService {
    static let shared = PlexOnDemandSubtitleService()

    func downloadBestSubtitle(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        language: String
    ) async -> PlexStream? {
        let normalizedLanguage = Self.searchLanguageCode(language) ?? language
        let candidates = await searchSubtitles(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey,
            language: normalizedLanguage
        )

        guard let candidate = candidates.first else {
            print("🎬 [Subtitles] Plex on-demand found no candidates ratingKey=\(ratingKey) language=\(normalizedLanguage)")
            return nil
        }

        do {
            try await downloadSubtitle(
                candidate,
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey
            )
            print("🎬 [Subtitles] Plex on-demand download requested ratingKey=\(ratingKey) language=\(normalizedLanguage) label=\(candidate.label ?? candidate.providerTitle ?? candidate.language)")

            return await pollDownloadedSubtitle(
                serverURL: serverURL,
                authToken: authToken,
                ratingKey: ratingKey,
                language: normalizedLanguage
            )
        } catch {
            print("🎬 [Subtitles] Plex on-demand download failed ratingKey=\(ratingKey) language=\(normalizedLanguage): \(error.localizedDescription)")
            return nil
        }
    }

    static func searchLanguageCode(_ value: String?) -> String? {
        guard let value = cleaned(value)?.lowercased(), value != "none" else {
            return nil
        }

        let normalized = value.split(separator: "-").first.map(String.init) ?? value
        switch normalized {
        case "eng", "english": return "en"
        case "spa", "esl", "spanish": return "es"
        case "fre", "fra", "french": return "fr"
        case "ger", "deu", "german": return "de"
        case "ita", "italian": return "it"
        case "por", "portuguese": return "pt"
        case "rus", "russian": return "ru"
        case "jpn", "japanese": return "ja"
        case "kor", "korean": return "ko"
        case "chi", "zho", "chinese": return "zh"
        case "ara", "arabic": return "ar"
        case "hin", "hindi": return "hi"
        case "hrv", "scr", "croatian": return "hr"
        case "srp", "scc", "serbian": return "sr"
        case "bos", "bosnian": return "bs"
        default:
            return normalized.count >= 2 ? String(normalized.prefix(2)) : normalized
        }
    }

    private func searchSubtitles(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        language: String
    ) async -> [PlexOnDemandSubtitleCandidate] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/subtitles") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "hearingImpaired", value: "0"),
            URLQueryItem(name: "forced", value: "0")
        ]

        guard let url = components.url else { return [] }

        do {
            let data = try await PlexNetworkManager.shared.requestData(
                url,
                headers: PlexNetworkManager.shared.plexHeaders(authToken: authToken)
            )
            let candidates = PlexOnDemandSubtitleSearchXMLParser().parse(data: data)
            print("🎬 [Subtitles] Plex on-demand search ratingKey=\(ratingKey) language=\(language) results=\(candidates.count)")
            return candidates
        } catch {
            print("🎬 [Subtitles] Plex on-demand search failed ratingKey=\(ratingKey) language=\(language): \(error.localizedDescription)")
            return []
        }
    }

    private func downloadSubtitle(
        _ candidate: PlexOnDemandSubtitleCandidate,
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/subtitles") else {
            throw PlexAPIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "key", value: candidate.key)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        _ = try await PlexNetworkManager.shared.requestData(
            url,
            method: "PUT",
            headers: PlexNetworkManager.shared.plexHeaders(authToken: authToken)
        )
    }

    private func pollDownloadedSubtitle(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        language: String
    ) async -> PlexStream? {
        for attempt in 0..<5 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }

            do {
                let metadata = try await PlexNetworkManager.shared.getMetadata(
                    serverURL: serverURL,
                    authToken: authToken,
                    ratingKey: ratingKey
                )

                let subtitleStreams = metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isSubtitle } ?? []
                if let match = subtitleStreams.first(where: {
                    $0.key != nil && Self.stream($0, matchesSearchLanguage: language)
                }) {
                    print("🎬 [Subtitles] Plex on-demand metadata ready ratingKey=\(ratingKey) language=\(language) stream=\(match.id)")
                    return match
                }
            } catch {
                print("🎬 [Subtitles] Plex on-demand poll failed ratingKey=\(ratingKey) attempt=\(attempt + 1): \(error.localizedDescription)")
            }
        }

        print("🎬 [Subtitles] Plex on-demand metadata did not expose a stream ratingKey=\(ratingKey) language=\(language)")
        return nil
    }

    private static func stream(_ stream: PlexStream, matchesSearchLanguage language: String) -> Bool {
        let candidates = [
            stream.languageTag,
            stream.languageCode,
            stream.language,
            stream.displayTitle,
            stream.extendedDisplayTitle,
            stream.title
        ]

        return candidates.contains { value in
            searchLanguageCode(value) == language
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

nonisolated struct PlexOnDemandSubtitleCandidate: Hashable, Sendable {
    let key: String
    let language: String
    let label: String?
    let hearingImpaired: Bool
    let forced: Bool
    let providerTitle: String?
    let score: Int
    let perfectMatch: Bool
}

nonisolated final class PlexOnDemandSubtitleSearchXMLParser: NSObject, XMLParserDelegate {
    private var candidates = Set<PlexOnDemandSubtitleCandidate>()

    func parse(data: Data) -> [PlexOnDemandSubtitleCandidate] {
        candidates.removeAll(keepingCapacity: true)
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        return candidates.sorted { lhs, rhs in
            if lhs.perfectMatch != rhs.perfectMatch {
                return lhs.perfectMatch && !rhs.perfectMatch
            }
            return lhs.score > rhs.score
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Stream" else { return }
        let streamType = Int(attributeDict["streamType"] ?? "") ?? 3
        guard streamType == 3 else { return }

        guard let key = cleaned(attributeDict["key"]) ?? cleaned(attributeDict["sourceKey"]) else {
            return
        }

        let language = PlexOnDemandSubtitleService.searchLanguageCode(
            cleaned(attributeDict["languageTag"])
                ?? cleaned(attributeDict["languageCode"])
                ?? cleaned(attributeDict["language"])
        ) ?? "und"
        let hearingImpaired = plexBoolean(attributeDict["hearingImpaired"])
        let forced = plexBoolean(attributeDict["forced"])
        let label = cleaned(attributeDict["displayTitle"])
            ?? cleaned(attributeDict["extendedDisplayTitle"])
            ?? cleaned(attributeDict["title"])
            ?? cleaned(attributeDict["providerTitle"])

        candidates.insert(
            PlexOnDemandSubtitleCandidate(
                key: key,
                language: language,
                label: label,
                hearingImpaired: hearingImpaired,
                forced: forced,
                providerTitle: cleaned(attributeDict["providerTitle"]),
                score: Int(attributeDict["score"] ?? "") ?? 0,
                perfectMatch: plexBoolean(attributeDict["perfectMatch"])
            )
        )
    }

    private func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func plexBoolean(_ value: String?) -> Bool {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "1" || normalized == "true" || normalized == "yes"
    }
}
