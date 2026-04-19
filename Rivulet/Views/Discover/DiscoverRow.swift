//
//  DiscoverRow.swift
//  Rivulet
//
//  Horizontal row of DiscoverTiles. Mirrors MediaRow's layout, padding,
//  spacing, focus, and onPress behavior so Discover blends with Home/Library.
//
//  Each tile has a long-press context menu offering Details + Add/Remove
//  Watchlist; tile selection emits a PreviewRequest into the unified carousel.
//

import SwiftUI

struct DiscoverRow: View {
    let title: String
    let items: [MediaItem]
    let isInLibrary: (MediaItem) -> Bool
    let isOnWatchlist: (MediaItem) -> Bool
    /// Emits a `PreviewRequest` rooted at the tapped tile so the unified
    /// carousel opens with the rest of the row as side cards.
    let onSelect: (PreviewRequest) -> Void

    @Environment(\.uiScale) private var scale

    private var titleSize: CGFloat { ScaledDimensions.sectionTitleSize * scale }
    private var horizontalPadding: CGFloat { ScaledDimensions.rowHorizontalPadding }
    private var itemSpacing: CGFloat { ScaledDimensions.rowItemSpacing * scale }

    @FocusState private var focusedItemId: String?

    private var rowID: String { "discover:\(title)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: titleSize, weight: .bold))
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: itemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            emitPreview(for: index)
                        } label: {
                            DiscoverTile(
                                item: item,
                                isInLibrary: isInLibrary(item),
                                isOnWatchlist: isOnWatchlist(item)
                            )
                        }
                        .buttonStyle(CardButtonStyle())
                        .focused($focusedItemId, equals: item.id)
                        .previewSourceAnchor(rowID: rowID, itemID: item.id)
                        .tmdbContextMenu(
                            item: item,
                            rowItems: items,
                            rowID: rowID,
                            onSelect: onSelect
                        )
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 32)
            }
            .scrollClipDisabled()
        }
        .focusSection()
        .defaultFocus($focusedItemId, items.first.map(\.id))
    }

    private func emitPreview(for index: Int) {
        guard items.indices.contains(index) else { return }
        onSelect(PreviewRequest(
            items: items,
            selectedIndex: index,
            sourceRowID: rowID,
            sourceItemID: items[index].id
        ))
    }
}
