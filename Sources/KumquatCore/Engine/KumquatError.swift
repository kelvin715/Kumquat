import Foundation

public enum KumquatError: LocalizedError, Sendable {
    case unsupportedInput(String)
    case unsupportedConversion(from: String, to: String)
    case decodeFailed(String)
    case encodeFailed(String)
    case toolMissing(String)
    case processFailed(String)
    case nothingToDo(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput(let name):
            return "\(name) isn't a file type Kumquat can open."
        case .unsupportedConversion(let from, let to):
            return "Can't convert \(from) to \(to)."
        case .decodeFailed(let name):
            return "Couldn't read \(name)."
        case .encodeFailed(let what):
            return "Couldn't write \(what)."
        case .toolMissing(let tool):
            return "This conversion needs \(tool). Install it with Homebrew: brew install \(tool)"
        case .processFailed(let message):
            return message
        case .nothingToDo(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}
