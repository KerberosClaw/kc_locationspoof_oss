import Foundation
import Combine

/// 常用位置收藏 — UserDefaults JSON 編碼持久化。
@MainActor
final class SavedLocationsStore: ObservableObject {
    private static let storageKey = "saved_locations"

    @Published private(set) var items: [SavedLocation] = []

    init() {
        load()
    }

    func add(name: String, coordinate: Coordinate) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty
            ? String(format: "%.4f, %.4f", coordinate.lat, coordinate.lon)
            : trimmed
        items.append(SavedLocation(name: final, coordinate: coordinate))
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to newName: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].name = newName
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([SavedLocation].self, from: data)
        else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
