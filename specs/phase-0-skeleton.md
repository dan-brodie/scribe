# Phase 0 — App Shell, DB Schema, State Machine, Logging

status: not-started

## Goal

Stand up the bare Scribe app: menu bar icon, GRDB schema with migrations, a working state machine, and structured logging — everything except real audio or calendar data.

## Acceptance Criteria

- [ ] App launches as a `MenuBarExtra` (no Dock icon; `LSUIElement = YES`)
- [ ] Menu bar icon has 5 states: idle, upcoming, recording, processing, error
- [ ] Settings scene stub opens from the menu (empty, just a window)
- [ ] Launch-at-login toggle works via `SMAppService`
- [ ] GRDB migration runs on first launch; `db.sqlite` created in `~/Library/Application Support/Scribe/`
- [ ] Schema matches spec: `meetings`, `attendees`, `speakers`, `actions`, `voiceProfiles`
- [ ] `StateMachine` transitions: `recorded → transcribed → diarized → summarized → exported` persisted to SQLite
- [ ] Invalid transitions are rejected with a logged error, not a crash
- [ ] Fake meeting rows advance through all states on a timer (demo mode for testing)
- [ ] `os.Logger` subsystem `com.scribe` set up; all services log with a category label
- [ ] `UserNotifications` framework integrated; permission requested on first launch
- [ ] Unit tests pass: state machine transitions, invalid-transition rejection, DB round-trip

## Key Files to Create

```
Scribe.xcodeproj
App/
  ScribeApp.swift           @main entry, MenuBarExtra setup
  MenuBarView.swift         menu contents, icon state binding
  SettingsView.swift        stub settings window
Core/
  AppCoordinator.swift      @Observable coordinator, owns state machine + DB
  StateMachine.swift        MeetingState enum + transition logic
  DB/
    Database.swift          DatabaseQueue init + migration runner
    Migrations.swift        all migration steps
    Models/
      Meeting.swift         GRDB record struct
      Attendee.swift
      Speaker.swift
      ActionItem.swift
      VoiceProfile.swift
Tests/
  StateMachineTests.swift
  DatabaseTests.swift
```

## Key APIs / Dependencies

- `SwiftUI.MenuBarExtra` (window style)
- `ServiceManagement.SMAppService` for launch-at-login
- `UserNotifications` framework
- `GRDB` — `DatabaseQueue`, `DatabaseMigrator`, `MutablePersistableRecord`
- `os.Logger(subsystem:category:)`

## Notes

- No SPM packages yet beyond GRDB — add FluidAudio + MLX in Phase 2/5
- State machine must be an `Actor` to be safe across async tasks
- Keep `AppCoordinator` thin — it orchestrates, services do work
