import os

/// Unified logging. Read with:
///   log show --last 10m --predicate 'subsystem == "io.github.kelvin715.Kumquat"'
enum Log {
    static let drag = Logger(subsystem: "io.github.kelvin715.Kumquat", category: "drag")
    static let work = Logger(subsystem: "io.github.kelvin715.Kumquat", category: "work")
}
