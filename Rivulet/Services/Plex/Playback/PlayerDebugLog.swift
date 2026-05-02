//
//  PlayerDebugLog.swift
//  Rivulet
//
//  Central debug logging helper for the RivuletPlayer pipeline.
//
//  In DEBUG builds this forwards to `print`.
//  In release builds it compiles to a no-op AND — thanks to `@autoclosure` —
//  the caller's string interpolation is never evaluated, so expensive
//  per-frame formatting (`String(format:)`, floating-point conversions,
//  nested lookups) does not execute.
//
//  Usage: `playerDebugLog("[DirectPlay] foo=\(bar)")`
//

import Foundation

@inline(__always)
nonisolated func playerDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
