//
//  DeepLinkHandlerDetailTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class DeepLinkHandlerDetailTests: XCTestCase {

    func testDetailURLSetsHost() {
        let url = URL(string: "rivulet://detail?ratingKey=12345")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.host, "detail")
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "ratingKey" })?.value,
            "12345"
        )
    }

    func testPlayURLSetsHost() {
        let url = URL(string: "rivulet://play?ratingKey=67890")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        XCTAssertEqual(components?.host, "play")
    }
}
