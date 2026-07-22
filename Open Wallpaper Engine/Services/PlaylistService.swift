//
//  PlaylistService.swift
//  Open Wallpaper Engine
//
//  Drives automatic wallpaper rotation (G5). The pure selection math lives in
//  PlaylistRotation; this type owns the repeating timer and applies the chosen
//  wallpaper to every enabled screen.
//

import Foundation

/// Owns the rotation timer and applies the next wallpaper on each tick.
///
/// The rotation pool is every valid installed wallpaper EXCEPT `web`/`application`
/// types: those go through a trust prompt in `WallpaperViewModel`, which must never
/// be raised unattended during a timed rotation. Excluding them lets us apply the
/// next wallpaper with the plain setter, no prompt path involved.
final class PlaylistService {
    private unowned let wallpaperViewModel: WallpaperViewModel
    /// Returns the current installed-wallpaper list. Injected so each tick sees a
    /// fresh snapshot (wallpapers can be added/removed while the app runs) and so
    /// the service stays testable.
    private let poolProvider: () -> [WEWallpaper]

    private var timer: Timer?
    private var settings = PlaylistSettings()
    /// Stable identity of what we last applied. `WEWallpaper.id` is a per-launch
    /// `hashValue`, so directory URL is the only safe cross-tick identifier.
    private var currentDirectory: URL?

    init(wallpaperViewModel: WallpaperViewModel,
         poolProvider: @escaping () -> [WEWallpaper]) {
        self.wallpaperViewModel = wallpaperViewModel
        self.poolProvider = poolProvider
    }

    // MARK: - Timer control

    /// Start, stop, or reschedule the timer to match `settings`.
    func reconfigure(with settings: PlaylistSettings) {
        self.settings = settings

        timer?.invalidate()
        timer = nil

        guard settings.enabled else { return }

        // Floor at one minute so a stray tiny value can't thrash the desktop.
        let interval = max(60, settings.intervalMinutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.advance()
        }
        // `.common` keeps the timer firing during menu tracking and window drags.
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    /// Advance immediately and restart the interval, so the menu-bar "Next
    /// Wallpaper" action never leaves a truncated partial interval behind.
    /// Works as a manual "shuffle to next" even when rotation is disabled.
    func advanceManually() {
        advance()
        reconfigure(with: settings)
    }

    // MARK: - Selection

    private func rotationPool() -> [WEWallpaper] {
        poolProvider()
            .filter { $0.project != .invalid }
            .filter { !["web", "application"].contains($0.project.type.lowercased()) }
            // Stable ordering by directory path so `sequential` is deterministic
            // regardless of the browser's current sort setting.
            .sorted { $0.wallpaperDirectory.path < $1.wallpaperDirectory.path }
    }

    private func advance() {
        let pool = rotationPool()
        guard !pool.isEmpty else { return }

        // Seed from whatever the main screen currently shows, so the first advance
        // moves off the visible wallpaper instead of jumping to index 0.
        if currentDirectory == nil {
            let mainId = WallpaperViewModel.mainScreenId()
            currentDirectory = wallpaperViewModel.wallpaper(for: mainId).wallpaperDirectory
        }

        let currentIdx = currentDirectory.flatMap { dir in
            pool.firstIndex { $0.wallpaperDirectory == dir }
        }
        guard let nextIdx = PlaylistRotation.nextIndex(count: pool.count,
                                                       currentIndex: currentIdx,
                                                       order: settings.order) else { return }

        let next = pool[nextIdx]
        currentDirectory = next.wallpaperDirectory

        // Apply to every enabled screen (all get the same wallpaper this tick —
        // independent per-monitor playlists are a future extension). Fall back to
        // the selected screen if somehow none are enabled.
        let targets = wallpaperViewModel.enabledScreens.isEmpty
            ? [wallpaperViewModel.selectedScreenId]
            : Array(wallpaperViewModel.enabledScreens)
        for screenId in targets {
            wallpaperViewModel.setWallpaper(next, for: screenId)
        }
    }
}
