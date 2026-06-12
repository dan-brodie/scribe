# GRDB.swift — Local API Reference

**Repo:** https://github.com/groue/GRDB.swift
**License:** MIT
**Latest:** v7.11.0 (Jun 2026)

## SPM Dependency

```swift
.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")
// target dependency:
.product(name: "GRDB", package: "GRDB.swift")
```

**Minimum:** macOS 10.15+, Swift 6.1+, Xcode 16.3+

## Database Setup

```swift
import GRDB

// Single writer, concurrent reads (recommended for this app)
let dbQueue = try DatabaseQueue(path: dbPath)

// Run migrations on startup
var migrator = DatabaseMigrator()
migrator.registerMigration("v1") { db in
    try db.create(table: "meetings") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("eventID", .text).notNull().unique()
        t.column("title", .text).notNull()
        t.column("start", .datetime).notNull()
        t.column("end", .datetime).notNull()
        t.column("state", .text).notNull().defaults(to: "recorded")
        t.column("exportPath", .text)
        t.column("error", .text)
    }
    // ... other tables
}
try migrator.migrate(dbQueue)
```

## Record Definition

```swift
struct Meeting: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var eventID: String
    var title: String
    var start: Date
    var end: Date
    var state: MeetingState  // custom enum, Codable
    var exportPath: String?
    var error: String?

    static let databaseTableName = "meetings"
}
```

## Common Operations

```swift
// Fetch
let all     = try dbQueue.read { db in try Meeting.fetchAll(db) }
let one     = try dbQueue.read { db in try Meeting.fetchOne(db, id: meetingID) }
let pending = try dbQueue.read { db in
    try Meeting.filter(Column("state") != "exported").fetchAll(db)
}

// Write
try dbQueue.write { db in
    var meeting = Meeting(...)
    try meeting.insert(db)         // sets meeting.id
    meeting.state = .transcribed
    try meeting.update(db)
    try meeting.delete(db)
}

// Observe changes (Combine)
let observation = ValueObservation.tracking { db in
    try Meeting.order(Column("start").desc).fetchAll(db)
}
let cancellable = observation.start(in: dbQueue, onError: { _ in }, onChange: { meetings in
    // update UI
})
```

## Schema Tables (this app)

```sql
meetings      (id INTEGER PK, eventID TEXT UNIQUE, title TEXT, start DATETIME,
               end DATETIME, state TEXT, exportPath TEXT, error TEXT)
attendees     (id INTEGER PK, meetingID INTEGER FK, name TEXT, email TEXT,
               role TEXT, rsvp TEXT)
speakers      (id INTEGER PK, meetingID INTEGER FK, label TEXT,
               assignedAttendee TEXT, confidence TEXT, provenance TEXT)
actions       (id INTEGER PK, meetingID INTEGER FK, owner TEXT, task TEXT,
               due TEXT, done INTEGER DEFAULT 0)
voiceProfiles (id INTEGER PK, personEmail TEXT UNIQUE, name TEXT,
               embeddingBlob BLOB, sampleCount INTEGER)
```

## Tips

- Use `DatabaseQueue` (not `DatabasePool`) for simplicity; WAL mode is on by default
- Store file in `~/Library/Application Support/Scribe/db.sqlite`
- `MutablePersistableRecord` is required when you let SQLite assign the `id` (autoincrement)
- Use `Column("field")` for type-safe query building; avoid raw SQL strings
