//
//  CastMemberCard.swift
//  Rivulet
//
//  Cast and crew member cards for detail view — circular photo style
//

import SwiftUI

// MARK: - Person Card (Circle)

/// Card for cast/crew members with circular photo, name, and role beneath
struct PersonCard: View {
    let name: String
    let subtitle: String?
    let thumbURL: URL?
    let serverURL: String
    let authToken: String

    private let circleSize: CGFloat = 140

    var body: some View {
        VStack(spacing: 10) {
            personImage
                .frame(width: circleSize, height: circleSize)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )

            VStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                if let subtitle = subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: circleSize + 20)
        }
    }

    // MARK: - Person Image

    private var personImage: some View {
        CachedAsyncImage(url: fullThumbURL) { phase in
            switch phase {
            case .empty:
                Circle()
                    .fill(Color(white: 0.15))
                    .overlay {
                        ProgressView()
                            .tint(.white.opacity(0.3))
                    }
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.18), Color(white: 0.12)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
    }

    private var fullThumbURL: URL? {
        guard let thumbPath = thumbURL?.absoluteString else { return nil }
        if thumbPath.hasPrefix("http") {
            return thumbURL
        }
        var urlString = "\(serverURL)\(thumbPath)"
        if !urlString.contains("X-Plex-Token") {
            urlString += urlString.contains("?") ? "&" : "?"
            urlString += "X-Plex-Token=\(authToken)"
        }
        return URL(string: urlString)
    }
}

// MARK: - Cast & Crew Row

/// Horizontal scrolling row of cast and crew members with circular photos
struct CastCrewRow: View {
    let cast: [PlexRole]
    let directors: [PlexCrewMember]
    let serverURL: String
    let authToken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Cast & Crew")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 48)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    // Directors first
                    ForEach(directors, id: \.id) { director in
                        Button { } label: {
                            PersonCard(
                                name: director.tag ?? "Unknown",
                                subtitle: "Director",
                                thumbURL: director.thumb.flatMap { URL(string: $0) },
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        .buttonStyle(CircleCardButtonStyle())
                    }

                    // Cast members
                    ForEach(cast, id: \.id) { actor in
                        Button { } label: {
                            PersonCard(
                                name: actor.tag ?? "Unknown",
                                subtitle: actor.role,
                                thumbURL: actor.thumb.flatMap { URL(string: $0) },
                                serverURL: serverURL,
                                authToken: authToken
                            )
                        }
                        .buttonStyle(CircleCardButtonStyle())
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

// MARK: - Circle Card Button Style

/// Subtle focus style for circular cast/crew cards
struct CircleCardButtonStyle: ButtonStyle {
    @FocusState private var isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .focused($isFocused)
            .hoverEffectDisabled()
            .focusEffectDisabled()
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
            .animation(.spring(response: 0.15, dampingFraction: 0.9), value: configuration.isPressed)
    }
}
