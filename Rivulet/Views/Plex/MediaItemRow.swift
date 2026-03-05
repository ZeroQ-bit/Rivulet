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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                #if os(tvOS)
                .font(.system(size: ScaledDimensions.sectionTitleSize, weight: .bold))
                #else
                .font(.title2)
                .fontWeight(.bold)
                #endif
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
                        #if os(tvOS)
                        .buttonStyle(CardButtonStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal, ScaledDimensions.rowHorizontalPadding)
                .padding(.vertical, ScaledDimensions.rowVerticalPadding)
            }
            .scrollClipDisabled()
        }
        .focusSection()
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
