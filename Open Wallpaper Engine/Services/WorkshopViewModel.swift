import Foundation
import SwiftUI
import Combine

class WorkshopViewModel: ObservableObject {
    @Published var items: [WorkshopItem] = []
    @Published var searchText = ""
    @Published var sortOrder: WorkshopSortOrder = .trending
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentPage = 1

    /// False once a page comes back short, meaning there is nothing left to page into.
    /// Drives whether the infinite-scroll trigger is still mounted.
    @Published private(set) var hasMore = true

    /// Set when a `loadMore` request fails. Infinite scroll stops auto-retrying while
    /// this is set — otherwise the trigger would re-fire on every redraw and hammer the
    /// API — and the view offers a manual retry instead.
    @Published private(set) var loadMoreFailed = false

    // Filters are grouped by Steam's official taxonomy rather than a single flat
    // tag list. Steam's QueryFiles has only one global `match_all_tags` switch, so
    // "OR within a group, AND across groups" (what the original Wallpaper Engine
    // does) isn't expressible server-side. We therefore keep single-select groups
    // (Rating/Type/Resolution) as server-side tag constraints and do the multi-select
    // Genre group's OR client-side — see `searchItems`.
    @Published var selectedRating: String = "Everyone"   // single-select (maturity ceiling)
    @Published var selectedType: String? = nil           // single-select, nil = any
    @Published var selectedResolution: String? = nil     // single-select, nil = any
    @Published var selectedCategory: String? = nil       // single-select, nil = any
    @Published var selectedGenres: Set<String> = []      // multi-select, OR (client-side)
    @Published var selectedMisc: Set<String> = []        // multi-select, AND (server-side)

    let steamCmd: SteamCmdService
    private let api = WorkshopAPIService()
    private var cancellable: AnyCancellable?

    static let contentRatingTags = ["Everyone", "Questionable", "Mature"]

    static let typeTags = ["Scene", "Video", "Web", "Application"]

    // Official 431960 Genre group (Steam readytouse_tags snapshot 2026-07-21).
    // Exact casing matters: these strings are matched against the tags Steam returns.
    static let genreTags = [
        "Abstract", "Animal", "Anime", "Cartoon", "CGI",
        "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
        "Landscape", "Medieval", "Memes", "MMD", "Music",
        "Nature", "Pixel art", "Relaxing", "Retro", "Sci-Fi",
        "Sports", "Technology", "Television", "Vehicle", "Unspecified",
    ]

    // Official 431960 Resolution group, full 25-value list (Steam readytouse_tags
    // snapshot 2026-07-21), in Steam's display order.
    static let resolutionTags = [
        "Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080",
        "2560 x 1440", "3840 x 2160",
        "Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440",
        "Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160",
        "Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080",
        "Triple 7680 x 1440", "Triple 11520 x 2160",
        "Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920",
        "Portrait 1440 x 2560", "Portrait 2160 x 3840",
        "Other resolution", "Dynamic resolution",
    ]

    // Official Category group (single-select).
    static let categoryTags = ["Wallpaper", "Preset", "Asset"]

    // Official Miscellaneous group (multi-select). Unlike Genre's OR, these are
    // narrowing attributes, so multiple selections AND together — which is
    // Steam's native `match_all_tags` behavior and can stay server-side.
    static let miscTags = [
        "Approved", "Audio responsive", "3D", "Customizable", "Puppet Warp",
        "HDR", "Media Integration", "User Shortcut", "Video Texture", "Asset Pack",
    ]

    /// Tags that must be present, sent as `requiredtags[]` (server-side, AND).
    var requiredTags: [String] {
        var tags: [String] = []
        if let selectedType { tags.append(selectedType) }
        if let selectedResolution { tags.append(selectedResolution) }
        if let selectedCategory { tags.append(selectedCategory) }
        tags.append(contentsOf: selectedMisc.sorted())
        return tags
    }

    /// Tags that must be absent, sent as `excludedtags[]`. Age rating is modelled as
    /// a maturity ceiling: "Everyone" hides both flagged buckets (and, unlike a
    /// requiredtag, still surfaces items that carry no rating tag at all).
    var excludedTags: [String] {
        switch selectedRating {
        case "Everyone": return ["Questionable", "Mature"]
        case "Questionable": return ["Mature"]
        default: return []   // "Mature" → show everything
        }
    }

    init(steamCmd: SteamCmdService) {
        self.steamCmd = steamCmd
        // Forward steamCmd changes (e.g. downloadProgress) to trigger view updates
        self.cancellable = steamCmd.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    @MainActor
    func search() async {
        isLoading = true
        errorMessage = nil
        // A fresh query invalidates any previous end-of-results / failure verdict.
        hasMore = true
        loadMoreFailed = false

        do {
            let page = try await api.searchItems(
                query: searchText,
                requiredTags: requiredTags,
                excludedTags: excludedTags,
                genreFilter: selectedGenres,
                sortOrder: sortOrder,
                page: currentPage
            )
            items = page.items
            hasMore = page.serverCount >= WorkshopAPIService.defaultPerPage
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }

        isLoading = false
    }

    /// Append the next page. Safe to call repeatedly from the infinite-scroll trigger:
    /// overlapping calls, an exhausted list, and a failed previous attempt all no-op.
    @MainActor
    func loadMore() async {
        guard !isLoading, hasMore, !loadMoreFailed else { return }

        // Only commit the page advance once the request succeeds, so a transient
        // failure doesn't silently skip a page on the next attempt.
        let nextPage = currentPage + 1
        isLoading = true

        do {
            let page = try await api.searchItems(
                query: searchText,
                requiredTags: requiredTags,
                excludedTags: excludedTags,
                genreFilter: selectedGenres,
                sortOrder: sortOrder,
                page: nextPage
            )
            currentPage = nextPage
            items.append(contentsOf: page.items)
            hasMore = page.serverCount >= WorkshopAPIService.defaultPerPage
        } catch {
            errorMessage = error.localizedDescription
            loadMoreFailed = true
        }

        isLoading = false
    }

    /// Clear a `loadMore` failure so the infinite-scroll trigger can fire again.
    @MainActor
    func retryLoadMore() async {
        guard loadMoreFailed else { return }
        loadMoreFailed = false
        errorMessage = nil
        await loadMore()
    }

    func download(item: WorkshopItem) {
        steamCmd.downloadWorkshopItem(workshopId: item.id)
    }

    func downloadState(for item: WorkshopItem) -> SteamCmdService.DownloadState? {
        steamCmd.downloadProgress[item.id]
    }

}
