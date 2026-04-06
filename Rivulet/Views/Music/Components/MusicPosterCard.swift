//
//  MusicPosterCard.swift
//  Rivulet
//
//  Artwork-first music poster card matching the Apple Music tvOS grid.
//

import SwiftUI

enum MusicPosterCardStyle {
    case square
    case circular
}

struct MusicPosterCard: View {
    let item: PlexMetadata
    var style: MusicPosterCardStyle = .square
    var onFocusChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool

    private let artworkSize: CGFloat = 198

    private var artworkURL: URL? {
        guard let thumb = item.thumb ?? item.parentThumb,
              let serverURL = PlexAuthManager.shared.selectedServerURL,
              let token = PlexAuthManager.shared.selectedServerToken else { return nil }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    private var subtitle: String? {
        guard resolvedStyle == .square else { return nil }
        return item.parentTitle ?? item.grandparentTitle
    }

    private var resolvedStyle: MusicPosterCardStyle {
        item.type == "artist" ? .circular : style
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                artworkView
                    .frame(width: artworkSize, height: artworkSize)
                    .scaleEffect(isFocused ? 1.055 : 1)
                    .brightness(isFocused ? 0.02 : 0)
                    .shadow(color: .black.opacity(isFocused ? 0.28 : 0.14), radius: isFocused ? 18 : 8, y: isFocused ? 12 : 5)

                Text(item.title ?? "Unknown")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(width: artworkSize + 8)
                    .multilineTextAlignment(.center)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .frame(width: artworkSize + 8)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .onChange(of: isFocused) { _, focused in
            onFocusChanged?(focused)
        }
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }

    @ViewBuilder
    private var artworkView: some View {
        CachedAsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty, .failure:
                placeholderView
            @unknown default:
                placeholderView
            }
        }
        .if(resolvedStyle == .circular) { view in
            view.clipShape(Circle())
        }
        .if(resolvedStyle == .square) { view in
            view.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var placeholderView: some View {
        Group {
            if resolvedStyle == .circular {
                Circle()
                    .fill(.white.opacity(0.07))
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 38, weight: .regular))
                            .foregroundStyle(.white.opacity(0.25))
                    }
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 38, weight: .regular))
                            .foregroundStyle(.white.opacity(0.28))
                    }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
