// Preference storage. Preferences are a single JSON blob under one settings key
// so adding a field later never needs a migration.

import Foundation

extension ClipboardStore {
    private static let preferencesKey = "preferences.v1"

    /// Reads the stored preferences, falling back to defaults when nothing has
    /// been saved or the blob is unreadable.
    public func preferences() throws -> Preferences {
        let statement = try database.prepare("SELECT value FROM settings WHERE key = ?")
        defer { statement.finalize() }
        try statement.bind(1, Self.preferencesKey)
        guard try statement.step(), let json = statement.string(at: 0) else {
            return .defaultValue
        }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data)
        else {
            return .defaultValue
        }
        return decoded.sanitized()
    }

    public func setPreferences(
        _ preferences: Preferences,
        willDelete: (([Int64]) -> Void)? = nil
    ) throws {
        let sanitized = preferences.sanitized()
        let data = try JSONEncoder().encode(sanitized)
        let json = String(decoding: data, as: UTF8.self)
        let victimIDs = try entriesToTrim(limit: sanitized.defaultMaxItems)
        if !victimIDs.isEmpty {
            if let onEntriesWillBeDeleted {
                let victims = try entries(ids: victimIDs)
                if !victims.isEmpty {
                    try onEntriesWillBeDeleted(victims, sanitized)
                }
            }
            willDelete?(victimIDs)
        }
        try database.transaction {
            let statement = try database.prepare("""
                INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)
                """)
            defer { statement.finalize() }
            try statement.bind(1, Self.preferencesKey)
            try statement.bind(2, json)
            try statement.run()

            try deleteRows(ids: victimIDs)
        }
    }
}
