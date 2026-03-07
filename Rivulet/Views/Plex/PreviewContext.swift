//
//  PreviewContext.swift
//  Rivulet
//
//  Shared state and preferences for the Apple TV-style row preview flow.
//

import SwiftUI

struct PreviewRequest: Identifiable {
    let id = UUID()
    let items: [PlexMetadata]
    let selectedIndex: Int
    let sourceRowID: String
    let sourceItemID: String

    var sourceTarget: PreviewSourceTarget {
        PreviewSourceTarget(rowID: sourceRowID, itemID: sourceItemID)
    }
}

enum PreviewPhase: Equatable {
    case enteringCarousel
    case carousel
    case expanding
    case expanded
}

enum PreviewFocusArea: Hashable {
    case carousel
    case heroPrimary
    case detailHeader
    case detailBody
}

struct PreviewSourceTarget: Hashable {
    let rowID: String
    let itemID: String
}

struct PreviewSourceFramePreferenceKey: PreferenceKey {
    static var defaultValue: [PreviewSourceTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [PreviewSourceTarget: Anchor<CGRect>], nextValue: () -> [PreviewSourceTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PreviewSourceAnchorModifier: ViewModifier {
    let rowID: String
    let itemID: String

    func body(content: Content) -> some View {
        content.anchorPreference(key: PreviewSourceFramePreferenceKey.self, value: .bounds) { anchor in
            [PreviewSourceTarget(rowID: rowID, itemID: itemID): anchor]
        }
    }
}

extension View {
    func previewSourceAnchor(rowID: String, itemID: String) -> some View {
        modifier(PreviewSourceAnchorModifier(rowID: rowID, itemID: itemID))
    }
}

enum PreviewBackAction: Equatable {
    case collapseToCarousel
    case dismissOverlay
}

struct PreviewStateMachine {
    private(set) var phase: PreviewPhase = .enteringCarousel

    var isCarouselInputEnabled: Bool {
        phase == .enteringCarousel || phase == .carousel
    }

    var isExpanded: Bool {
        phase == .expanding || phase == .expanded
    }

    mutating func completeEntry() {
        guard phase == .enteringCarousel else { return }
        phase = .carousel
    }

    mutating func beginExpand() {
        guard phase == .carousel || phase == .enteringCarousel else { return }
        phase = .expanding
    }

    mutating func finishExpand() {
        guard phase == .expanding else { return }
        phase = .expanded
    }

    mutating func collapseToCarousel() {
        phase = .carousel
    }

    mutating func exitAction() -> PreviewBackAction {
        switch phase {
        case .enteringCarousel, .carousel:
            return .dismissOverlay
        case .expanding, .expanded:
            phase = .carousel
            return .collapseToCarousel
        }
    }
}

struct PreviewLoadGate {
    private(set) var generation: Int = 0

    @discardableResult
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}
