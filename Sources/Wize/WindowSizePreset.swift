import Foundation

struct WindowSizePreset: Codable, Equatable {
    var name: String
    var width: Int
    var height: Int

    var size: CGSize { CGSize(width: width, height: height) }
    var title: String { name.isEmpty ? "\(width) × \(height)" : "\(name) — \(width) × \(height)" }

    static let defaults: [WindowSizePreset] = [
        .init(name: "", width: 800, height: 600),
        .init(name: "", width: 1024, height: 768),
        .init(name: "HD", width: 1280, height: 720),
        .init(name: "", width: 1440, height: 900),
        .init(name: "Full HD", width: 1920, height: 1080),
    ]

    /// Persisted as JSON in UserDefaults; seeded with `defaults`, all entries renamable/deletable.
    static var all: [WindowSizePreset] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "presets"),
                  let list = try? JSONDecoder().decode([WindowSizePreset].self, from: data) else { return defaults }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "presets") }
    }
}
