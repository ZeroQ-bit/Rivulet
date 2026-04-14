//
//  DiscoverRow.swift
//  Rivulet
//
//  Horizontal row of DiscoverTiles for one TMDB section.
//

import SwiftUI

struct DiscoverRow: View {
    let title: String
    let items: [TMDBListItem]
    let isInLibrary: (TMDBListItem) -> Bool
    let isOnWatchlist: (TMDBListItem) -> Bool
    let onSelect: (TMDBListItem) -> Void

    @FocusState private var focusedItemId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    ForEach(items) { item in
                        DiscoverTile(
                            item: item,
                            isInLibrary: isInLibrary(item),
                            isOnWatchlist: isOnWatchlist(item),
                            onTap: { onSelect(item) }
                        )
                        .focused($focusedItemId, equals: String(item.id))
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 12)
            }
        }
        .focusSection()
        .remembersFocus(key: "discoverRow:\(title)", focusedId: $focusedItemId)
    }
}
