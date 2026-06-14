// SPDX-License-Identifier: MIT

import Foundation
import GRDB

/// A stored voice embedding used to recognize a recurring speaker across
/// meetings. Populated only when the "Remember voices" toggle is on.
struct VoiceProfile: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var personEmail: String
    var name: String
    var embeddingBlob: Data
    var sampleCount: Int

    static let databaseTableName = "voiceProfiles"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
