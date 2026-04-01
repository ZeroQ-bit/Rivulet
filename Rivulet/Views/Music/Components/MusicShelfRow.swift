//
//  MusicShelfRow.swift
//  Rivulet
//
//  Reusable horizontal shelf row for music content
//

import SwiftUI

/// Horizontal shelf of music poster cards with a title header.
/// Used throughout the music UI for album/artist browsing shelves.
struct MusicShelfRow: View {
    let title: String
    let items: [PlexMetadata]
    let onSelect: (PlexMetadata) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Spacer()

                if items.count > 6 {
                    Text("See All")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 50)

            // Horizontal scroll of poster cards
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(items, id: \.ratingKey) { item in
                        MusicPosterCard(item: item) {
                            onSelect(item)
                        }
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 8)
            }
            .focusSection()
        }
    }
}
