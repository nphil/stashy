import Foundation
import VideoEngine

/// The viewer's choice for "Enhance picture" (engine 3.0.0). `off` is the default and means the engine builds nothing.
enum EnhanceMode: String, CaseIterable, Identifiable {
    case off, automatic, lineArt

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Automatic"
        case .lineArt: return "Line art"
        }
    }

    /// The engine's scaler choice for this mode.
    var upscaler: EnhanceOptions.Upscaler {
        switch self {
        case .off: return .off
        case .automatic: return .automatic
        case .lineArt: return .lineArt
        }
    }
}

/// Persisted "Enhance picture" values. One global setting, read by every `ScenePlayerModel` when it is created.
enum EnhanceSettings {
    static let modeKey = "player.enhance.mode"
    static let sharpenKey = "player.enhance.sharpen"
    static let debandKey = "player.enhance.deband"

    static let defaultSharpen = 0.3
    static let defaultDeband = 0.2

    static var storedMode: EnhanceMode {
        EnhanceMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .off
    }
    static var storedSharpen: Double {
        UserDefaults.standard.object(forKey: sharpenKey) as? Double ?? defaultSharpen
    }
    static var storedDeband: Double {
        UserDefaults.standard.object(forKey: debandKey) as? Double ?? defaultDeband
    }
}
