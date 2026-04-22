//
//  PagedResult.swift
//  Rivulet
//
//  Pagination primitives for provider browse methods.
//

import Foundation

struct Page: Sendable, Hashable {
    let offset: Int
    let limit: Int
}

struct PagedResult<T: Sendable>: Sendable {
    let items: [T]
    let total: Int
    let nextPage: Page?
}

enum SortOption: Sendable, Hashable, Codable {
    case titleAsc
    case titleDesc
    case releaseDateDesc
    case addedAtDesc
    case ratingDesc
}
