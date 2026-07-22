//
//  PlaylistRotation.swift
//  Open Wallpaper Engine
//
//  Pure, dependency-free rotation logic and persisted config for the wallpaper
//  playlist (G5). Deliberately AppKit-free so it can be unit-tested in isolation
//  (see the standalone rotation test).
//

import Foundation

/// Order in which the playlist advances through the installed wallpapers.
enum GSPlaylistOrder: String, CaseIterable, Identifiable, Codable {
    var id: Self { self }
    case sequential, shuffle
}

/// Auto-rotation config. Persisted under its OWN UserDefaults key (not folded
/// into `GlobalSettings`) so that shipping this feature can never fail to decode
/// an older `GlobalSettings` blob and silently reset the user's other settings.
struct PlaylistSettings: Codable, Equatable {
    var enabled = false
    /// Interval between switches, in minutes.
    var intervalMinutes: Double = 15
    var order: GSPlaylistOrder = .sequential
}

enum PlaylistRotation {
    /// Index of the next wallpaper to show.
    ///
    /// - Parameters:
    ///   - count: number of wallpapers in the rotation pool.
    ///   - currentIndex: index currently displayed, or `nil` if none / not found.
    ///   - order: sequential wrap-around, or shuffle.
    ///   - randomIndex: injectable RNG for shuffle — given `count`, returns a value
    ///     in `0..<count`. Defaults to `Int.random`; exposed so tests stay
    ///     deterministic.
    /// - Returns: the next index, or `nil` when the pool is empty.
    static func nextIndex(count: Int,
                          currentIndex: Int?,
                          order: GSPlaylistOrder,
                          randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }

        switch order {
        case .sequential:
            // `currentIndex ?? -1` makes a fresh start (nil) land on index 0.
            // The modulo also tolerates a stale index left over from a shrunken pool.
            let base = currentIndex ?? -1
            return (base + 1) % count
        case .shuffle:
            // Never re-pick the current wallpaper: a shuffle that "advances" to the
            // same item looks like a frozen rotation.
            var pick = randomIndex(count) % count
            if let current = currentIndex, pick == current {
                pick = (pick + 1) % count
            }
            return pick
        }
    }
}
