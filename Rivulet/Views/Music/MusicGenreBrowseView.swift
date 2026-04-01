//
//  MusicGenreBrowseView.swift
//  Rivulet
//
//  Browse music library by genre with filterable grid.
//

import SwiftUI

struct MusicGenreBrowseView: View {
    let libraryKey: String
    @StateObject private var authManager = PlexAuthManager.shared
    @State private var genres: [String] = []
    @State private var selectedGenre: String?
    @State private var filteredAlbums: [PlexMetadata] = []
    @State private var isLoadingGenres = true
    @State private var isLoadingAlbums = false
    @FocusState private var focusedGenre: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 32) {
                Text(selectedGenre ?? "Genres")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 60)

                if isLoadingGenres {
                    ProgressView().tint(.white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                } else if selectedGenre == nil {
                    genreGrid
                } else {
                    albumsForGenre
                }
            }
            .padding(.vertical, 40)
        }
        .onExitCommand {
            if selectedGenre != nil {
                selectedGenre = nil
                filteredAlbums = []
            }
        }
        .task { await loadGenres() }
    }

    private var genreGrid: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 200, maximum: 250), spacing: 16)
        ], spacing: 16) {
            ForEach(genres, id: \.self) { genre in
                Button {
                    selectedGenre = genre
                    Task { await loadAlbumsForGenre(genre) }
                } label: {
                    Text(genre)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 100)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(focusedGenre == genre ? .white.opacity(0.18) : .white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            focusedGenre == genre ? .white.opacity(0.25) : .white.opacity(0.08),
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
                .focused($focusedGenre, equals: genre)
                .scaleEffect(focusedGenre == genre ? 1.03 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focusedGenre == genre)
            }
        }
        .padding(.horizontal, 60)
    }

    private var albumsForGenre: some View {
        Group {
            if isLoadingAlbums {
                ProgressView().tint(.white.opacity(0.3))
                    .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 200), spacing: 24)
                ], spacing: 24) {
                    ForEach(filteredAlbums, id: \.ratingKey) { album in
                        MusicPosterCard(item: album, onSelect: {
                            // Navigation to album detail would go here
                        })
                    }
                }
                .padding(.horizontal, 60)
            }
        }
    }

    private func loadGenres() async {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            // Load all albums to extract genres
            let hubs = try await PlexNetworkManager.shared.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: libraryKey
            )

            var genreSet = Set<String>()
            for hub in hubs {
                for item in hub.Metadata ?? [] {
                    for genre in item.Genre ?? [] {
                        if let tag = genre.tag {
                            genreSet.insert(tag)
                        }
                    }
                }
            }
            genres = genreSet.sorted()
        } catch {
            print("Failed to load genres: \(error)")
        }
        isLoadingGenres = false
    }

    private func loadAlbumsForGenre(_ genre: String) async {
        isLoadingAlbums = true
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }

        do {
            guard var components = URLComponents(string: "\(serverURL)/library/sections/\(libraryKey)/all") else { return }
            components.queryItems = [
                URLQueryItem(name: "type", value: "9"),
                URLQueryItem(name: "genre", value: genre),
                URLQueryItem(name: "X-Plex-Token", value: token)
            ]
            guard let url = components.url else { return }
            let data = try await PlexNetworkManager.shared.requestData(url, method: "GET", headers: ["X-Plex-Token": token])
            let response = try JSONDecoder().decode(PlexResponse.self, from: data)
            filteredAlbums = response.MediaContainer.Metadata ?? []
        } catch {
            print("Failed to load albums for genre: \(error)")
        }
        isLoadingAlbums = false
    }
}
