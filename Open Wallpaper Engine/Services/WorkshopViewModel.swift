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

    // Filters are grouped by Steam's official taxonomy rather than a single flat
    // tag list. Steam's QueryFiles has only one global `match_all_tags` switch, so
    // "OR within a group, AND across groups" (what the original Wallpaper Engine
    // does) isn't expressible server-side. We therefore keep single-select groups
    // (Rating/Type/Resolution) as server-side tag constraints and do the multi-select
    // Genre group's OR client-side — see `searchItems`.
    @Published var selectedRating: String = "Everyone"   // single-select (maturity ceiling)
    @Published var selectedType: String? = nil           // single-select, nil = any
    @Published var selectedResolution: String? = nil     // single-select, nil = any
    @Published var selectedGenres: Set<String> = []      // multi-select, OR

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

    // Common Resolution group values (verified-working subset of the official list).
    static let resolutionTags = [
        "1920 x 1080", "2560 x 1440", "3840 x 2160",
        "3440 x 1440", "1440 x 2560",
    ]

    /// Tags that must be present, sent as `requiredtags[]` (server-side, AND).
    var requiredTags: [String] {
        var tags: [String] = []
        if let selectedType { tags.append(selectedType) }
        if let selectedResolution { tags.append(selectedResolution) }
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

        do {
            let results = try await api.searchItems(
                query: searchText,
                requiredTags: requiredTags,
                excludedTags: excludedTags,
                genreFilter: selectedGenres,
                sortOrder: sortOrder,
                page: currentPage
            )
            items = results
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    func loadMore() async {
        currentPage += 1
        isLoading = true

        do {
            let results = try await api.searchItems(
                query: searchText,
                requiredTags: requiredTags,
                excludedTags: excludedTags,
                genreFilter: selectedGenres,
                sortOrder: sortOrder,
                page: currentPage
            )
            items.append(contentsOf: results)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func download(item: WorkshopItem) {
        steamCmd.downloadWorkshopItem(workshopId: item.id)
    }

    func downloadState(for item: WorkshopItem) -> SteamCmdService.DownloadState? {
        steamCmd.downloadProgress[item.id]
    }

    // MARK: - Filter selection

    func selectRating(_ tag: String) {
        selectedRating = tag
        currentPage = 1
    }

    /// Single-select groups toggle off when the active value is tapped again.
    func selectType(_ tag: String) {
        selectedType = (selectedType == tag) ? nil : tag
        currentPage = 1
    }

    func selectResolution(_ tag: String) {
        selectedResolution = (selectedResolution == tag) ? nil : tag
        currentPage = 1
    }

    func toggleGenre(_ tag: String) {
        if selectedGenres.contains(tag) {
            selectedGenres.remove(tag)
        } else {
            selectedGenres.insert(tag)
        }
        currentPage = 1
    }
}
