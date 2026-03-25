import XCTest
@testable import Rivulet

final class SubtitleParserTests: XCTestCase {
    func testASSParserParsesDialogueAndOverrideTags() throws {
        let ass = """
        [Script Info]
        Title: Example

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\an8}Hello\\NWorld
        Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,Second line
        """

        let track = try ASSParser().parse(ass)
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].startTime, 1.0, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].endTime, 3.5, accuracy: 0.001)
        XCTAssertEqual(track.cues[0].text, "Hello\nWorld")
    }

    func testSubtitleFormatMapsASSAndSSA() {
        assertASS(SubtitleFormat(from: "ass"))
        assertASS(SubtitleFormat(from: "ssa"))
        assertASS(SubtitleFormat(fromURL: URL(fileURLWithPath: "/tmp/test.ass")))
        assertASS(SubtitleFormat(fromURL: URL(fileURLWithPath: "/tmp/test.ssa")))
    }

    private func assertASS(_ format: SubtitleFormat, file: StaticString = #filePath, line: UInt = #line) {
        if case .ass = format {
            return
        }
        XCTFail("Expected ASS subtitle format", file: file, line: line)
    }
}
