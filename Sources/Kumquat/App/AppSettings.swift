import Combine
import Foundation
import KumquatCore

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    enum Language: String, CaseIterable, Identifiable {
        case system, english, chinese
        var id: String { rawValue }
    }

    @Published var wheelDiameter: Double { didSet { defaults.set(wheelDiameter, forKey: "wheelDiameter") } }
    @Published var imageQuality: Double { didSet { defaults.set(imageQuality, forKey: "imageQuality") } }
    @Published var compressQuality: Double { didSet { defaults.set(compressQuality, forKey: "compressQuality") } }
    @Published var pdfDPI: Double { didSet { defaults.set(pdfDPI, forKey: "pdfDPI") } }
    @Published var webpLossless: Bool { didSet { defaults.set(webpLossless, forKey: "webpLossless") } }
    @Published var revealAfterSaving: Bool { didSet { defaults.set(revealAfterSaving, forKey: "revealAfterSaving") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }
    @Published var useExternalTools: Bool { didSet { defaults.set(useExternalTools, forKey: "useExternalTools") } }
    @Published var hapticFeedback: Bool { didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") } }
    @Published var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "language") } }

    private init() {
        defaults.register(defaults: [
            "wheelDiameter": 260.0,
            "imageQuality": 0.9,
            "compressQuality": 0.65,
            "pdfDPI": 300.0,
            "webpLossless": false,
            "revealAfterSaving": false,
            "playSound": true,
            "useExternalTools": true,
            "hapticFeedback": true,
            "hasSeenWelcome": false,
            "language": Language.system.rawValue,
        ])
        wheelDiameter = defaults.double(forKey: "wheelDiameter")
        imageQuality = defaults.double(forKey: "imageQuality")
        compressQuality = defaults.double(forKey: "compressQuality")
        pdfDPI = defaults.double(forKey: "pdfDPI")
        webpLossless = defaults.bool(forKey: "webpLossless")
        revealAfterSaving = defaults.bool(forKey: "revealAfterSaving")
        playSound = defaults.bool(forKey: "playSound")
        useExternalTools = defaults.bool(forKey: "useExternalTools")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        language = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
    }

    var conversionOptions: ConversionOptions {
        var o = ConversionOptions()
        o.imageQuality = imageQuality
        o.compressQuality = compressQuality
        o.pdfDPI = pdfDPI
        o.webpLossless = webpLossless
        return o
    }

    var capabilities: Capabilities { Capabilities.detect(useExternalTools: useExternalTools) }
}
