//
//  TopShelfCache.swift
//  Rivulet
//
//  Manages shared cache for Top Shelf extension via App Groups
//

import Foundation

/// Manages read/write access to Top Shelf data in the shared App Group container
/// Used by both the main app (write) and TV Services Extension (read)
final class TopShelfCache: Sendable {
    static let shared = TopShelfCache()

    private let appGroupIdentifier = "group.app.rivulet"
    private let cacheFileName = "top_shelf_items.json"

    private init() {}

    // MARK: - Container Access

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private var cacheFileURL: URL? {
        containerURL?.appendingPathComponent(cacheFileName)
    }

    // MARK: - UserDefaults Suite (more reliable than file access)

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private let userDefaultsKey = "topShelfItems"

    // MARK: - Write (Main App)

    /// Write Top Shelf items to the shared container
    /// Called by PlexDataStore when Continue Watching data is refreshed
    func writeItems(_ items: [TopShelfItem]) {

        guard let defaults = sharedDefaults else {
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            defaults.set(data, forKey: userDefaultsKey)
            defaults.synchronize()

            // Debug: print first item
        } catch {
        }
    }

    // MARK: - Read (Extension)

    /// Read Top Shelf items from the shared container
    /// Called by TV Services Extension to display items
    func readItems() -> [TopShelfItem] {
        guard let defaults = sharedDefaults else {
            return []
        }

        guard let data = defaults.data(forKey: userDefaultsKey) else {
            return []
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([TopShelfItem].self, from: data)
            return items
        } catch {
            return []
        }
    }

    // MARK: - Clear

    /// Remove all cached Top Shelf items
    func clear() {
        sharedDefaults?.removeObject(forKey: userDefaultsKey)
    }
}
