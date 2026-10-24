import Foundation

let codexHelperAppGroupIdentifier = "PCJ84YD7HQ.com.makerjackie.codex-helper"
let codexHelperWidgetKind = "CodexHelperQuotaWidget"

struct WidgetQuotaWindow: Codable, Equatable {
    let id: String
    let name: String
    let planType: String?
    let remainingPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?
}

struct WidgetQuotaSnapshot: Codable, Equatable {
    let windows: [WidgetQuotaWindow]
    let resetCredits: Int
    let fetchedAt: Date

    var isValid: Bool {
        func validDate(_ date: Date) -> Bool {
            date.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains(date.timeIntervalSince1970)
        }
        return windows.count <= 100 && resetCredits >= 0 && validDate(fetchedAt) &&
            Set(windows.map(\.id)).count == windows.count && windows.allSatisfy {
                !$0.id.isEmpty && $0.id.count <= 256 && $0.remainingPercent.isFinite &&
                (0...100).contains($0.remainingPercent) &&
                ($0.windowDurationMins == nil || $0.windowDurationMins! > 0) &&
                ($0.resetsAt == nil || validDate($0.resetsAt!))
            }
    }
}

enum WidgetSnapshotStore {
    private static let fileName = "quota-widget.json"

    static func load() -> WidgetQuotaSnapshot? {
        guard let file = try? FileHandle(forReadingFrom: snapshotURL) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 128_001) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> WidgetQuotaSnapshot? {
        guard data.count <= 128_000,
              let snapshot = try? decoder.decode(WidgetQuotaSnapshot.self, from: data), snapshot.isValid else { return nil }
        return snapshot
    }

    @discardableResult
    static func save(_ snapshot: WidgetQuotaSnapshot) -> Bool {
        guard snapshot.isValid, let data = try? encoder.encode(snapshot), data.count <= 128_000 else { return false }
        do {
            try FileManager.default.createDirectory(
                at: snapshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: snapshotURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static var snapshotURL: URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: codexHelperAppGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(fileName)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHelper", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
