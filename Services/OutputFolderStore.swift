// SPDX-License-Identifier: MIT

import Foundation

/// Persists the user-chosen notes output folder.
///
/// Stores a bookmark (security-scoped when the app is sandboxed) so the choice
/// survives the folder being moved or renamed; falls back to the default
/// `~/Documents/Meeting Notes/` when nothing is chosen or the bookmark can no
/// longer be resolved. A non-sandboxed build resolves the same bookmark without
/// the entitlement; under the sandbox, `com.apple.security.files.user-selected.read-write`
/// is required (ADR / Phase 6 risk note).
struct OutputFolderStore: Sendable {
    private let defaults: UserDefaults
    private let key = "outputFolderBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `~/Documents/Meeting Notes/`.
    static var defaultFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        return documents.appendingPathComponent("Meeting Notes", isDirectory: true)
    }

    /// The resolved output folder, or the default if unset/unresolvable. A stale
    /// bookmark is refreshed in place.
    func folder() -> URL {
        guard let data = defaults.data(forKey: key) else { return Self.defaultFolder }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return Self.defaultFolder
        }
        if stale { setFolder(url) }
        return url
    }

    /// Persist the user's chosen folder as a bookmark.
    func setFolder(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        defaults.set(data, forKey: key)
    }
}
