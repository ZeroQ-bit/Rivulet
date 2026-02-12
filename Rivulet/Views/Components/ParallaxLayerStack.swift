//
//  ParallaxLayerStack.swift
//  Rivulet
//
//  Shadow-based depth effect for poster images using foreground cutout
//

import SwiftUI
import UIKit

/// Composites a foreground subject cutout over the original image with a drop shadow
/// on focus to create a 3D "lifted" depth effect. No scaling - just shadow appears.
struct ParallaxLayerStack: View {
    let originalImage: UIImage
    let foregroundImage: UIImage
    let isFocused: Bool
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    // MARK: - Animation Parameters (Design Guide: Elegant Restraint)

    /// Shadow color
    private let shadowColor: Color = .black

    /// Shadow opacity when focused
    private var shadowOpacity: Double { isFocused ? 0.7 : 0 }

    /// Shadow blur radius when focused (smaller = harder edge)
    private var shadowRadius: CGFloat { isFocused ? 6 : 0 }

    /// Shadow Y offset when focused (downward)
    private var shadowY: CGFloat { isFocused ? 4 : 0 }

    var body: some View {
        ZStack {
            // Background: Original image (always visible, provides context behind shadow)
            Image(uiImage: originalImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)

            // Foreground: Subject cutout with drop shadow on focus
            Image(uiImage: foregroundImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .shadow(
                    color: shadowColor.opacity(shadowOpacity),
                    radius: shadowRadius,
                    x: 0,
                    y: shadowY
                )
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isFocused)
    }
}

#if DEBUG
struct ParallaxLayerStack_Previews: PreviewProvider {
    static var previews: some View {
        ParallaxLayerStack(
            originalImage: UIImage(systemName: "person.fill")!,
            foregroundImage: UIImage(systemName: "person.fill")!,
            isFocused: true,
            width: 220,
            height: 330,
            cornerRadius: 12
        )
    }
}
#endif
