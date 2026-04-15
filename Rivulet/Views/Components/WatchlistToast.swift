//
//  WatchlistToast.swift
//  Rivulet
//
//  Transient bottom-of-screen message surfaced by PlexWatchlistService when a
//  write optimistically reverts. Auto-hides; consumers simply bind to the
//  service's `transientWriteError` publisher.
//

import SwiftUI

struct WatchlistToastModifier: ViewModifier {
    let message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                    .background(
                        Capsule()
                            .fill(.black.opacity(0.7))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                    )
                    .padding(.bottom, 80)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: message)
    }
}

extension View {
    func watchlistToast(message: String?) -> some View {
        modifier(WatchlistToastModifier(message: message))
    }
}
