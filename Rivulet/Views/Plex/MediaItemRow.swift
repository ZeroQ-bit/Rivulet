//
//  MediaItemRow.swift
//  Rivulet
//
//  Reusable horizontal scroll row for displaying media items (collections, recommendations)
//

import SwiftUI

/// Horizontal scrolling row of media items with poster cards
struct MediaItemRow: View {
    let title: String
    let items: [PlexMetadata]
    let serverURL: String
    let authToken: String
    /// Called when an item is selected - allows parent to handle navigation/replacement
    var onItemSelected: ((PlexMetadata) -> Void)?
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    @Environment(\.uiScale) private var scale

    private var isMusicRow: Bool {
        guard let firstItem = items.first else { return false }
        return firstItem.type == "album" || firstItem.type == "artist" || firstItem.type == "track"
    }

    private var rowCardHeight: CGFloat {
        (isMusicRow ? ScaledDimensions.squarePosterSize : ScaledDimensions.posterHeight) * scale
    }

    private var compactScrollHeight: CGFloat {
        rowCardHeight + (ScaledDimensions.rowVerticalPadding * 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: ScaledDimensions.sectionTitleSize, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ScaledDimensions.rowItemSpacing) {
                    ForEach(items, id: \.ratingKey) { item in
                        Button {
                            onItemSelected?(item)
                        } label: {
                            MediaPosterCard(
                                item: item,
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        .buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)
            }
            .scrollClipDisabled()
            .frame(height: compactScrollHeight)
        }
        .focusSection()
        .onMoveCommand { direction in
            switch direction {
            case .up:
                onMoveUp?()
            case .down:
                onMoveDown?()
            default:
                break
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        MediaItemRow(
            title: "Collection Title",
            items: [],
            serverURL: "",
            authToken: ""
        )
    }
}
