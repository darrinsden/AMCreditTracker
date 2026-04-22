//
//  AMCreditTrackerApp.swift
//  AM Credit Tracker
//
//  A single-file skeleton for AM Credit Tracker, the Jacent Strategic Merchandising
//  area manager credit limit tracking app. Drop this file into a new
//  iOS App project in Xcode (iOS 17+, Swift 5.9+, SwiftData).
//
//  Scope covered:
//    - SwiftData @Model types: Product, ScanSession, ScannedItem,
//      CatalogSync, AreaManager
//    - ScanSessionStore: @Observable in-memory store for the active
//      scan session, owns the running subtotal and limit logic
//    - CatalogService: UPC lookup backed by SwiftData
//    - SyncService: SharePoint/CSV pull, parse, atomic catalog replace
//    - AudioService: error buzzer via AudioServices
//    - ScanView: keyboard-wedge scanner input, buzzer on over-limit,
//      manual override sheet on UPC miss
//
//  Not yet wired here (add as follow-ups):
//    - HistoryView, SessionDetailView, SettingsView, ManualPriceSheet
//      body layouts — stubs only
//    - Microsoft Graph / SharePoint auth (MSAL) — replace the URL
//      fetch in SyncService.fetchCSV()
//    - BGAppRefreshTask registration in AppDelegate — commented hook
//      provided
//

import SwiftUI
import SwiftData
import AudioToolbox
import AVFoundation
import BackgroundTasks
import VisionKit
import Vision
import MessageUI

// MARK: - App entry

@main
struct AMCreditTrackerApp: App {
    // Shared SwiftData container. All five @Model types registered here.
    let container: ModelContainer = {
        do {
            let schema = Schema([
                Product.self,
                ScanSession.self,
                ScannedItem.self,
                CatalogSync.self,
                AreaManager.self,
                AreaManagerSync.self,
                Store.self,
                StoreSync.self,
                TerritoryManager.self,
                TerritoryManagerSync.self
            ])
            let config = ModelConfiguration(schema: schema)
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("ModelContainer failed: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            LaunchCoordinator()
                .environment(ScanSessionStore())
                .task {
                    // Prime the audio service so its session config runs
                    // during launch, not on first scan.
                    _ = AudioService.shared
                    // AM roster syncs on app launch only. The catalog
                    // has its own schedule (foreground + BGAppRefresh).
                    await syncAreaManagersOnLaunch()
                }
        }
        .modelContainer(container)
    }

    private func syncAreaManagersOnLaunch() async {
        // Run all four syncs in parallel. Roster blocks the UI
        // (LaunchCoordinator waits on it). The others run non-blocking —
        // the UI loads immediately and each table populates in the
        // background while the AM picks their identity.
        async let roster: Void = RosterSyncCoordinator.shared.run(container: container)
        async let catalog: Void = CatalogSyncCoordinator.shared.run(container: container)
        async let stores: Void = StoreSyncCoordinator.shared.run(container: container)
        async let tms: Void = TerritoryManagerSyncCoordinator.shared.run(container: container)
        _ = await (roster, catalog, stores, tms)
    }
}

// MARK: - Roster sync coordinator

// Shared, observable handle to the launch-time AM roster sync. The
// LoadingRosterView watches this to show syncing / failed / done states,
// and lets the user retry without relaunching the app.
@Observable
final class RosterSyncCoordinator {
    static let shared = RosterSyncCoordinator()

    enum State {
        case idle
        case syncing
        case succeeded(count: Int)
        case failed(message: String)
    }

    var state: State = .idle

    // Google Drive share URL for area_managers.csv.
    // Either share link format works — the SyncService normalizes it.
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1rOFqR8IDo4lEJmT39tHtw7JsLggOauxf")!

    private init() {}

    @MainActor
    func run(container: ModelContainer) async {
        state = .syncing
        let service = SyncService(sourceURL: sourceURL)
        let record = await service.syncAreaManagers(into: container)
        let context = ModelContext(container)
        context.insert(record)
        try? context.save()
        switch record.status {
        case .success: state = .succeeded(count: record.managerCount)
        case .failed, .partial: state = .failed(message: record.errorMessage ?? "Unknown error")
        }
    }
}

// Background catalog sync. Runs at app launch alongside the roster sync,
// but unlike the roster sync, this is non-blocking — the app UI loads
// immediately and the catalog populates when ready. This lets the AM
// start navigating while we pull the product list in the background.
@Observable
@MainActor
final class CatalogSyncCoordinator {
    static let shared = CatalogSyncCoordinator()

    enum State {
        case idle
        case syncing
        case succeeded(count: Int)
        case failed(message: String)
    }

    var state: State = .idle

    // Google Drive share URL for catalog.csv.
    // Either share link format works — the SyncService normalizes it.
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n")!

    private init() {}

    @MainActor
    func run(container: ModelContainer) async {
        state = .syncing
        let service = SyncService(sourceURL: sourceURL)
        let record = await service.sync(into: container)
        let context = ModelContext(container)
        context.insert(record)
        try? context.save()
        switch record.status {
        case .success: state = .succeeded(count: record.productCount)
        case .failed, .partial: state = .failed(message: record.errorMessage ?? "Unknown error")
        }
    }
}

// Background stores sync. Runs at app launch alongside the roster and
// catalog syncs. Populates the Store table, which drives the two
// dependent pickers on the scan screen.
@Observable
@MainActor
final class StoreSyncCoordinator {
    static let shared = StoreSyncCoordinator()

    enum State {
        case idle
        case syncing
        case succeeded(count: Int)
        case failed(message: String)
    }

    var state: State = .idle

    // Google Drive share URL for stores.csv.
    // Either share link format works — the SyncService normalizes it.
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1WtggB4_n1G2avUV4q0Di4VRjG2ZdrEh3")!

    private init() {}

    @MainActor
    func run(container: ModelContainer) async {
        state = .syncing
        let service = SyncService(sourceURL: sourceURL)
        let record = await service.syncStores(into: container)
        let context = ModelContext(container)
        context.insert(record)
        try? context.save()
        switch record.status {
        case .success: state = .succeeded(count: record.storeCount)
        case .failed, .partial: state = .failed(message: record.errorMessage ?? "Unknown error")
        }
    }
}

// Background territory-managers sync. Runs at app launch. Populates the
// TerritoryManager table, which the submit flow uses to look up the TM's
// email when an over-limit credit needs written approval.
@Observable
@MainActor
final class TerritoryManagerSyncCoordinator {
    static let shared = TerritoryManagerSyncCoordinator()

    enum State {
        case idle
        case syncing
        case succeeded(count: Int)
        case failed(message: String)
    }

    var state: State = .idle

    // Google Drive share URL for territory_managers.csv.
    // Either share link format works — the SyncService normalizes it.
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1eJ7rQLkO9uCwATuPfPCxvSX-jIRnggss")!

    private init() {}

    @MainActor
    func run(container: ModelContainer) async {
        state = .syncing
        let service = SyncService(sourceURL: sourceURL)
        let record = await service.syncTerritoryManagers(into: container)
        let context = ModelContext(container)
        context.insert(record)
        try? context.save()
        switch record.status {
        case .success: state = .succeeded(count: record.managerCount)
        case .failed, .partial: state = .failed(message: record.errorMessage ?? "Unknown error")
        }
    }
}

// MARK: - Models (SwiftData)

@Model
final class Product {
    // UPC is no longer unique — the same UPC can appear in multiple stores
    // (e.g. Target vs. Walmart carrying the same product at different
    // prices). The composite (upc, store) is the logical primary key,
    // enforced at sync time by the full-replace catalog sync rather than
    // a DB constraint.
    var upc: String
    var name: String
    // Wholesale / credit price — the value that accumulates against
    // the session's $149.99 limit.
    var price: Decimal
    // Merchandising bucket. In the source CSV this column is now
    // labeled "commodity"; the in-app field is still named `category`
    // for back-compat with the rest of this project. The parser is
    // positional, so the rename in the CSV header is a no-op here.
    var category: String?
    // Store name (the retailer chain: "Target", "Walmart"). The specific
    // store number is NOT on the product — it's on the Store entity below,
    // which maps chains to their specific numbered locations.
    var store: String
    // Retail price (what the item sells for on the shelf). Optional so
    // rows that don't yet carry it parse cleanly.
    var retailPrice: Decimal?
    // Merchandising rank — lower-is-better ordering hint from the
    // catalog source. Optional because older/partial catalogs omit it.
    var rank: Int?
    var lastUpdated: Date

    init(upc: String,
         name: String,
         price: Decimal,
         category: String? = nil,
         store: String = "",
         retailPrice: Decimal? = nil,
         rank: Int? = nil,
         lastUpdated: Date = .now) {
        self.upc = upc
        self.name = name
        self.price = price
        self.category = category
        self.store = store
        self.retailPrice = retailPrice
        self.rank = rank
        self.lastUpdated = lastUpdated
    }
}

// Store entity: maps a store name (retailer chain) to its specific
// numbered locations. Populated from stores.csv. A single store name
// typically has multiple store numbers (e.g. "Target" has #1842,
// #4213, etc.). Each store is also scoped to an area so the scan
// screen can filter the picker to only the stores the signed-in AM
// actually covers.
@Model
final class Store {
    var store: String
    var storeNumber: String
    var area: String
    // Optional compact label for cramped UI surfaces (e.g. history rows,
    // picker summaries). Empty string = no shortname set; callers should
    // fall back to `store`. Kept in addition to `store` rather than
    // replacing it so the canonical name stays available for emails,
    // print headers, and CSV round-trips.
    var shortName: String
    var lastUpdated: Date

    init(store: String,
         storeNumber: String,
         area: String = "",
         shortName: String = "",
         lastUpdated: Date = .now) {
        self.store = store
        self.storeNumber = storeNumber
        self.area = area
        self.shortName = shortName
        self.lastUpdated = lastUpdated
    }

    /// What to show in space-constrained UI. Uses shortName when
    /// provided, otherwise falls back to the full store name.
    var displayName: String {
        shortName.isEmpty ? store : shortName
    }
}

@Model
final class AreaManager {
    @Attribute(.unique) var employeeNumber: String
    var firstName: String
    var lastName: String
    var territory: String   // broader grouping
    var area: String        // the AM's slice within a territory
    var email: String       // for CC on TM approval emails; empty if unknown

    var fullName: String { "\(firstName) \(lastName)" }

    init(employeeNumber: String,
         firstName: String,
         lastName: String,
         territory: String,
         area: String,
         email: String = "") {
        self.employeeNumber = employeeNumber
        self.firstName = firstName
        self.lastName = lastName
        self.territory = territory
        self.area = area
        self.email = email
    }
}

// Maps each territory to the email address of its Territory Manager.
// Used when an AM submits an over-limit credit request that requires
// written approval — we compose an email To: the TM for that territory,
// CC: the submitting AM.
@Model
final class TerritoryManager {
    @Attribute(.unique) var territory: String
    var email: String
    var lastUpdated: Date

    init(territory: String, email: String, lastUpdated: Date = .now) {
        self.territory = territory
        self.email = email
        self.lastUpdated = lastUpdated
    }
}

@Model
final class TerritoryManagerSync {
    @Attribute(.unique) var id: UUID
    var syncedAt: Date
    var managerCount: Int
    var sourceUrl: String
    var statusRaw: String
    var errorMessage: String?

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         syncedAt: Date = .now,
         managerCount: Int,
         sourceUrl: String,
         status: SyncStatus,
         errorMessage: String? = nil) {
        self.id = id
        self.syncedAt = syncedAt
        self.managerCount = managerCount
        self.sourceUrl = sourceUrl
        self.statusRaw = status.rawValue
        self.errorMessage = errorMessage
    }
}

enum SessionStatus: String, Codable, CaseIterable {
    case active
    case submitted
    case abandoned
    case overLimit
}

@Model
final class ScanSession {
    @Attribute(.unique) var id: UUID
    var employeeNumber: String           // FK -> AreaManager.employeeNumber
    var startedAt: Date
    var submittedAt: Date?
    var totalAmount: Decimal
    var statusRaw: String
    var notes: String?
    var storeNumber: String?
    var catalogSyncedAt: Date?           // catalog freshness at session time

    // Relationship: a session has many scanned items. Deleting a session
    // cascades to its items.
    @Relationship(deleteRule: .cascade, inverse: \ScannedItem.session)
    var items: [ScannedItem] = []

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         employeeNumber: String,
         startedAt: Date = .now,
         status: SessionStatus = .active,
         storeNumber: String? = nil,
         catalogSyncedAt: Date? = nil) {
        self.id = id
        self.employeeNumber = employeeNumber
        self.startedAt = startedAt
        self.submittedAt = nil
        self.totalAmount = 0
        self.statusRaw = status.rawValue
        self.notes = nil
        self.storeNumber = storeNumber
        self.catalogSyncedAt = catalogSyncedAt
    }
}

@Model
final class ScannedItem {
    @Attribute(.unique) var id: UUID
    var upc: String
    // Denormalized: we store the name/price AT SCAN TIME so the audit
    // log reflects historical prices even if the catalog changes later.
    var name: String
    var price: Decimal
    var quantity: Int
    var manualOverride: Bool
    var overrideNote: String?
    var scannedAt: Date

    var session: ScanSession?

    // Line total = price × quantity. Kept as a computed property so
    // audit readers don't risk stale values from manual edits.
    var lineTotal: Decimal {
        price * Decimal(quantity)
    }

    init(id: UUID = UUID(),
         upc: String,
         name: String,
         price: Decimal,
         quantity: Int = 1,
         manualOverride: Bool = false,
         overrideNote: String? = nil,
         scannedAt: Date = .now,
         session: ScanSession? = nil) {
        self.id = id
        self.upc = upc
        self.name = name
        self.price = price
        self.quantity = quantity
        self.manualOverride = manualOverride
        self.overrideNote = overrideNote
        self.scannedAt = scannedAt
        self.session = session
    }
}

enum SyncStatus: String, Codable {
    case success
    case failed
    case partial
}

@Model
final class CatalogSync {
    @Attribute(.unique) var id: UUID
    var syncedAt: Date
    var productCount: Int
    var sourceUrl: String
    var statusRaw: String
    var errorMessage: String?

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         syncedAt: Date = .now,
         productCount: Int,
         sourceUrl: String,
         status: SyncStatus,
         errorMessage: String? = nil) {
        self.id = id
        self.syncedAt = syncedAt
        self.productCount = productCount
        self.sourceUrl = sourceUrl
        self.statusRaw = status.rawValue
        self.errorMessage = errorMessage
    }
}

@Model
final class AreaManagerSync {
    @Attribute(.unique) var id: UUID
    var syncedAt: Date
    var managerCount: Int
    var sourceUrl: String
    var statusRaw: String
    var errorMessage: String?

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         syncedAt: Date = .now,
         managerCount: Int,
         sourceUrl: String,
         status: SyncStatus,
         errorMessage: String? = nil) {
        self.id = id
        self.syncedAt = syncedAt
        self.managerCount = managerCount
        self.sourceUrl = sourceUrl
        self.statusRaw = status.rawValue
        self.errorMessage = errorMessage
    }
}

// Parallel audit record for the stores.csv sync.
@Model
final class StoreSync {
    @Attribute(.unique) var id: UUID
    var syncedAt: Date
    var storeCount: Int
    var sourceUrl: String
    var statusRaw: String
    var errorMessage: String?

    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(),
         syncedAt: Date = .now,
         storeCount: Int,
         sourceUrl: String,
         status: SyncStatus,
         errorMessage: String? = nil) {
        self.id = id
        self.syncedAt = syncedAt
        self.storeCount = storeCount
        self.sourceUrl = sourceUrl
        self.statusRaw = status.rawValue
        self.errorMessage = errorMessage
    }
}

// MARK: - Session store (in-memory, observable)

// The active scan session lives in memory while an AM is scanning.
// Only on submit does it get persisted as a ScanSession. Abandoned
// sessions stay out of the audit log unless explicitly saved.
@Observable
final class ScanSessionStore {
    struct InMemoryItem: Identifiable, Hashable {
        let id: UUID
        let upc: String
        let name: String
        let price: Decimal
        var quantity: Int
        let manualOverride: Bool
        let overrideNote: String?
        let scannedAt: Date

        init(id: UUID = UUID(),
             upc: String,
             name: String,
             price: Decimal,
             quantity: Int = 1,
             manualOverride: Bool,
             overrideNote: String?,
             scannedAt: Date) {
            self.id = id
            self.upc = upc
            self.name = name
            self.price = price
            self.quantity = quantity
            self.manualOverride = manualOverride
            self.overrideNote = overrideNote
            self.scannedAt = scannedAt
        }

        var lineTotal: Decimal {
            price * Decimal(quantity)
        }
    }

    static let hardLimit: Decimal = 149.99
    static let warnThreshold: Decimal = 134.99   // 90% of 149.99

    var items: [InMemoryItem] = []
    var currentEmployeeNumber: String = "UNASSIGNED"
    var currentStoreNumber: String?

    var subtotal: Decimal {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    var isOverLimit: Bool {
        subtotal > Self.hardLimit
    }

    var isApproachingLimit: Bool {
        subtotal >= Self.warnThreshold && subtotal <= Self.hardLimit
    }

    var percentOfLimit: Double {
        let pct = (subtotal as NSDecimalNumber).doubleValue / (Self.hardLimit as NSDecimalNumber).doubleValue
        return min(1.0, max(0.0, pct))
    }

    func add(_ item: InMemoryItem) {
        items.append(item)
        if isOverLimit {
            AudioService.shared.playOverLimitBuzzer()
        } else {
            AudioService.shared.playScanConfirm()
        }
    }

    func remove(_ item: InMemoryItem) {
        items.removeAll { $0.id == item.id }
    }

    // Adjusts quantity on an existing line. Minimum 1 — use remove() to
    // take the item off entirely. Re-plays the buzzer if the change
    // pushes the session over the limit.
    func setQuantity(id: UUID, quantity: Int) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let wasOverLimit = isOverLimit
        items[idx].quantity = max(1, quantity)
        if !wasOverLimit && isOverLimit {
            AudioService.shared.playOverLimitBuzzer()
        }
    }

    func clear() {
        items.removeAll()
    }

    // Persist the active session to SwiftData.
    @MainActor
    func submit(into context: ModelContext, catalogSyncedAt: Date?) throws {
        guard !items.isEmpty else { return }

        let session = ScanSession(
            employeeNumber: currentEmployeeNumber,
            status: isOverLimit ? .overLimit : .submitted,
            storeNumber: currentStoreNumber,
            catalogSyncedAt: catalogSyncedAt
        )
        session.submittedAt = .now
        session.totalAmount = subtotal

        for memItem in items {
            let scanned = ScannedItem(
                upc: memItem.upc,
                name: memItem.name,
                price: memItem.price,
                quantity: memItem.quantity,
                manualOverride: memItem.manualOverride,
                overrideNote: memItem.overrideNote,
                scannedAt: memItem.scannedAt,
                session: session
            )
            session.items.append(scanned)
            context.insert(scanned)
        }
        context.insert(session)
        try context.save()
        clear()
    }
}

// MARK: - Catalog service

// Wraps UPC lookup, scoped to a specific store. A single UPC may appear
// in the catalog multiple times (once per store) with different prices
// and metadata — the scan screen provides the store context to disambiguate.
struct CatalogService {
    let context: ModelContext

    // Result of a UPC lookup, distinguishing three outcomes:
    // - .found: UPC exists in this store's catalog
    // - .wrongStore: UPC exists in the catalog but for a different store
    // - .notInCatalog: UPC doesn't exist anywhere in the catalog
    enum LookupResult {
        case found(Product)
        case wrongStore(availableAt: [String]) // list of store names where it is stocked
        case notInCatalog
    }

    // Store-scoped lookup. Matches UPC format-flexibly (12-digit UPC-A vs
    // 13-digit EAN-13) AND scopes the result to a specific store (retailer
    // chain). Returns a LookupResult so the caller can distinguish "wrong
    // store" from "not in catalog" in UI messaging.
    //
    // Note: the catalog tracks products per *store* (retailer), not per
    // *store number*. Two Target stores share the same catalog. Store
    // number is tracked separately on the scan session for audit.
    func lookup(upc: String, store: String) -> LookupResult {
        let candidates = upcCandidates(from: upc)

        // First pass: exact store match
        for candidate in candidates {
            let descriptor = FetchDescriptor<Product>(
                predicate: #Predicate {
                    $0.upc == candidate && $0.store == store
                }
            )
            if let match = try? context.fetch(descriptor).first {
                return .found(match)
            }
        }

        // Second pass: UPC is in catalog but for different store(s)?
        var otherStores: [String] = []
        for candidate in candidates {
            let descriptor = FetchDescriptor<Product>(
                predicate: #Predicate { $0.upc == candidate }
            )
            if let matches = try? context.fetch(descriptor) {
                for m in matches {
                    if !m.store.isEmpty && !otherStores.contains(m.store) {
                        otherStores.append(m.store)
                    }
                }
            }
        }

        return otherStores.isEmpty ? .notInCatalog : .wrongStore(availableAt: otherStores)
    }

    private func upcCandidates(from upc: String) -> [String] {
        var list = [upc]
        if upc.count == 13 && upc.hasPrefix("0") {
            list.append(String(upc.dropFirst()))
        }
        if upc.count == 12 {
            list.append("0" + upc)
        }
        return list
    }

    func lastSyncedAt() -> Date? {
        var descriptor = FetchDescriptor<CatalogSync>(
            predicate: #Predicate { $0.statusRaw == "success" },
            sortBy: [SortDescriptor(\.syncedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first?.syncedAt
    }

    func productCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<Product>())) ?? 0
    }
}

// MARK: - Store service

// Wraps the Store table with helpers for the dependent pickers on the
// scan screen: one for distinct store names (chains), and one for the
// store numbers filtered to a specific chain. All methods accept an
// optional area filter so the scan screen can scope results to
// the signed-in AM's area.
//
// When `area` is empty string, no filtering is applied (returns
// all stores). This handles the partial-migration case where stores.csv
// doesn't yet have an area column.
struct StoreService {
    let context: ModelContext

    // Distinct store names (chains), sorted alphabetically, optionally
    // filtered to a single area.
    func distinctStoreNames(in area: String = "") -> [String] {
        let all = (try? context.fetch(FetchDescriptor<Store>())) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for s in all where !s.store.isEmpty {
            // If an area filter is requested, only include stores
            // that either match the area OR have no area set
            // (partial-migration safety).
            if !area.isEmpty && !s.area.isEmpty && s.area != area {
                continue
            }
            if !seen.contains(s.store) {
                seen.insert(s.store)
                result.append(s.store)
            }
        }
        return result.sorted()
    }

    // Store numbers assigned to a given store chain, sorted, optionally
    // filtered to a single area.
    func storeNumbers(for storeName: String, in area: String = "") -> [String] {
        let descriptor = FetchDescriptor<Store>(
            predicate: #Predicate { $0.store == storeName }
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        let filtered = matches.filter { s in
            if area.isEmpty { return true }
            if s.area.isEmpty { return true }
            return s.area == area
        }
        return filtered.map { $0.storeNumber }.sorted()
    }

    func storeCount() -> Int {
        (try? context.fetchCount(FetchDescriptor<Store>())) ?? 0
    }
}

// MARK: - Sync service

// Pulls the catalog CSV from a shared source and replaces the local
// Product table atomically. For SharePoint, swap fetchCSV() for a
// Microsoft Graph call using MSAL — see comments at the call site.
//
// CSV format expected (first row is header):
//   upc,name,price,commodity,store,retailPrice,rank
//   037000127116,Tide Pods 42ct,19.99,Laundry,Target,24.99,1
//
// Columns 4 onward are optional for backward compatibility. `price`
// is the wholesale/credit price that counts against the session limit;
// `retailPrice` is the shelf price, displayed separately. `rank` is a
// numeric merchandising priority (lower = more prominent). The source
// column previously labeled "category" is now labeled "commodity"; the
// parser is positional so either header name works, and the in-app
// field is still named `category`.
//
// Prices parse as Decimal via NSDecimalNumber(string:) to avoid
// floating-point drift.
actor SyncService {
    enum SyncError: Error {
        case badResponse
        case malformedCSV(line: Int, reason: String)
        case emptyCatalog
        case emptyRoster
        case emptyStores
        case emptyTerritoryManagers
    }

    struct ParsedProduct {
        let upc: String
        let name: String
        let price: Decimal
        let category: String?
        let store: String
        let retailPrice: Decimal?
        let rank: Int?
    }

    let sourceURL: URL

    init(sourceURL: URL) {
        self.sourceURL = Self.normalizeSourceURL(sourceURL)
    }

    // Accepts either a Google Drive share URL or a direct-download URL
    // and returns the form that returns raw bytes on GET. This lets
    // whoever configures the app paste whatever URL is in their
    // clipboard, whether it's from Drive's "Share" dialog or from a
    // previously-configured deployment.
    //
    // Share URLs look like:
    //   https://drive.google.com/file/d/<ID>/view?usp=sharing
    //   https://drive.google.com/open?id=<ID>
    // Both normalize to:
    //   https://drive.google.com/uc?export=download&id=<ID>
    //
    // Non-Google-Drive URLs pass through unchanged, so self-hosted CSVs,
    // S3 URLs, and internal endpoints still work.
    static func normalizeSourceURL(_ url: URL) -> URL {
        let urlString = url.absoluteString
        guard urlString.contains("drive.google.com") else { return url }

        // Extract the file ID from either URL format
        let fileID: String?
        if let range = urlString.range(of: "/file/d/") {
            let afterPrefix = urlString[range.upperBound...]
            let id = afterPrefix.split(separator: "/").first.map(String.init)
            fileID = id
        } else if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let id = comps.queryItems?.first(where: { $0.name == "id" })?.value {
            fileID = id
        } else {
            fileID = nil
        }

        guard let id = fileID,
              let normalized = URL(string: "https://drive.google.com/uc?export=download&id=\(id)") else {
            return url
        }
        return normalized
    }

    // Top-level sync. Fetches, parses, then hands off to MainActor for
    // the atomic SwiftData replace.
    func sync(into container: ModelContainer) async -> CatalogSync {
        let startURL = sourceURL.absoluteString
        do {
            let csv = try await fetchCSV()
            let parsed = try parse(csv: csv)
            guard !parsed.isEmpty else { throw SyncError.emptyCatalog }
            let count = try await applyAtomicReplace(parsed: parsed, container: container)
            return CatalogSync(productCount: count, sourceUrl: startURL, status: .success)
        } catch {
            return CatalogSync(
                productCount: 0,
                sourceUrl: startURL,
                status: .failed,
                errorMessage: String(describing: error)
            )
        }
    }

    // Fetches the CSV from Google Drive's direct-download endpoint.
    // The sourceURL can be either format — a Drive share link or the
    // direct-download URL. The initializer normalizes it.
    //
    // If Jacent ever moves to authenticated sources (Google Workspace
    // restricted, Microsoft 365 with MSAL, or an internal REST API),
    // this is the single place to swap in auth headers:
    //
    //   var req = URLRequest(url: sourceURL)
    //   req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    //   let (data, resp) = try await URLSession.shared.data(for: req)
    //
    // The rest of the sync pipeline is auth-agnostic.
    private func fetchCSV() async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: sourceURL)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SyncError.badResponse
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SyncError.badResponse
        }
        return text
    }

    // Minimal CSV parser. Assumes no embedded commas/quotes in product
    // names — if the catalog has those, swap in a real CSV lib.
    private func parse(csv: String) throws -> [ParsedProduct] {
        var result: [ParsedProduct] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw SyncError.emptyCatalog }

        for (idx, rawLine) in lines.enumerated() where idx > 0 {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count >= 3 else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "expected at least 3 columns")
            }
            let upc = cols[0].trimmingCharacters(in: .whitespaces)
            let name = cols[1].trimmingCharacters(in: .whitespaces)
            let priceStr = cols[2].trimmingCharacters(in: .whitespaces)
            let category = cols.count >= 4 ? cols[3].trimmingCharacters(in: .whitespaces) : nil
            // Column 5 is the store (retailer chain). If absent (older
            // catalog format), default to empty string — products with an
            // empty store can only be matched when the AM's selected store
            // is also empty, so these effectively won't scan until the
            // catalog is re-synced with the new format.
            let store = cols.count >= 5 ? cols[4].trimmingCharacters(in: .whitespaces) : ""

            // Column 6: retailPrice (shelf price). Parsed when numeric,
            // left nil on empty/unparseable values so one bad row doesn't
            // tank the whole sync.
            var retailPrice: Decimal? = nil
            if cols.count >= 6 {
                let s = cols[5].trimmingCharacters(in: .whitespaces)
                if !s.isEmpty {
                    let d = NSDecimalNumber(string: s)
                    if d != .notANumber { retailPrice = d as Decimal }
                }
            }
            // Column 7: rank (merchandising priority, lower is better).
            // Same lenient rules as retailPrice.
            var rank: Int? = nil
            if cols.count >= 7 {
                let s = cols[6].trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { rank = Int(s) }
            }

            let decimal = NSDecimalNumber(string: priceStr)
            guard decimal != .notANumber else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "price not a number")
            }
            result.append(ParsedProduct(
                upc: upc,
                name: name,
                price: decimal as Decimal,
                category: category,
                store: store,
                retailPrice: retailPrice,
                rank: rank
            ))
        }
        return result
    }

    // Atomic replace: delete all existing Products, then insert new rows,
    // in a single save. If anything throws, the context discards changes.
    @MainActor
    private func applyAtomicReplace(parsed: [ParsedProduct], container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        try context.delete(model: Product.self)
        let now = Date.now
        for p in parsed {
            context.insert(Product(
                upc: p.upc,
                name: p.name,
                price: p.price,
                category: p.category,
                store: p.store,
                retailPrice: p.retailPrice,
                rank: p.rank,
                lastUpdated: now
            ))
        }
        try context.save()
        return parsed.count
    }

    // MARK: Area manager sync
    //
    // CSV format expected (first row is header):
    //   employeeNumber,firstName,lastName,territory,area
    //   12345,Darrin,Jessup,East,Seattle-North
    //
    // Called on app launch from AMCreditTrackerApp. Full replace each time —
    // matches the catalog's sync pattern. No upsert logic since
    // AreaManager has no local-only state to preserve.

    struct ParsedAreaManager {
        let employeeNumber: String
        let firstName: String
        let lastName: String
        let territory: String
        let area: String
        let email: String
    }

    func syncAreaManagers(into container: ModelContainer) async -> AreaManagerSync {
        let startURL = sourceURL.absoluteString
        do {
            let csv = try await fetchCSV()
            let parsed = try parseAreaManagers(csv: csv)
            guard !parsed.isEmpty else { throw SyncError.emptyRoster }
            let count = try await applyAtomicReplaceAreaManagers(parsed: parsed, container: container)
            return AreaManagerSync(managerCount: count, sourceUrl: startURL, status: .success)
        } catch {
            return AreaManagerSync(
                managerCount: 0,
                sourceUrl: startURL,
                status: .failed,
                errorMessage: String(describing: error)
            )
        }
    }

    private func parseAreaManagers(csv: String) throws -> [ParsedAreaManager] {
        var result: [ParsedAreaManager] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw SyncError.emptyRoster }

        for (idx, rawLine) in lines.enumerated() where idx > 0 {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count >= 5 else {
                throw SyncError.malformedCSV(
                    line: idx + 1,
                    reason: "expected at least 5 columns: employeeNumber, firstName, lastName, territory, area[, email]"
                )
            }
            let employeeNumber = cols[0].trimmingCharacters(in: .whitespaces)
            let firstName = cols[1].trimmingCharacters(in: .whitespaces)
            let lastName = cols[2].trimmingCharacters(in: .whitespaces)
            let territory = cols[3].trimmingCharacters(in: .whitespaces)
            let area = cols[4].trimmingCharacters(in: .whitespaces)
            // Column 6 (email) is optional — older rosters without it
            // still work; affected AMs just won't be CCd on approval
            // emails until the column is populated.
            let email = cols.count >= 6 ? cols[5].trimmingCharacters(in: .whitespaces) : ""

            guard !employeeNumber.isEmpty else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "employeeNumber is empty")
            }
            result.append(ParsedAreaManager(
                employeeNumber: employeeNumber,
                firstName: firstName,
                lastName: lastName,
                territory: territory,
                area: area,
                email: email
            ))
        }
        return result
    }

    @MainActor
    private func applyAtomicReplaceAreaManagers(parsed: [ParsedAreaManager], container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        try context.delete(model: AreaManager.self)
        for am in parsed {
            context.insert(AreaManager(
                employeeNumber: am.employeeNumber,
                firstName: am.firstName,
                lastName: am.lastName,
                territory: am.territory,
                area: am.area,
                email: am.email
            ))
        }
        try context.save()
        return parsed.count
    }

    // MARK: Stores sync
    //
    // CSV format expected (first row is header):
    //   store,storeNumber,area,shortName
    //   Target,1842,Seattle-North,TGT
    //   Target,4213,Seattle-North,TGT
    //   Walmart,0051,Seattle-North,WMT
    //
    // Columns 3 (area) and 4 (shortName) are optional for backward
    // compatibility — older CSVs with just `store,storeNumber` still
    // parse cleanly. shortName, when present, is shown in compact UI
    // (history rows, pickers) in place of the full store name.

    struct ParsedStore {
        let store: String
        let storeNumber: String
        let area: String
        let shortName: String
    }

    func syncStores(into container: ModelContainer) async -> StoreSync {
        let startURL = sourceURL.absoluteString
        do {
            let csv = try await fetchCSV()
            let parsed = try parseStores(csv: csv)
            guard !parsed.isEmpty else { throw SyncError.emptyStores }
            let count = try await applyAtomicReplaceStores(parsed: parsed, container: container)
            return StoreSync(storeCount: count, sourceUrl: startURL, status: .success)
        } catch {
            return StoreSync(
                storeCount: 0,
                sourceUrl: startURL,
                status: .failed,
                errorMessage: String(describing: error)
            )
        }
    }

    private func parseStores(csv: String) throws -> [ParsedStore] {
        var result: [ParsedStore] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw SyncError.emptyStores }

        for (idx, rawLine) in lines.enumerated() where idx > 0 {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count >= 2 else {
                throw SyncError.malformedCSV(
                    line: idx + 1,
                    reason: "expected at least 2 columns: store, storeNumber [, area, shortName]"
                )
            }
            let store = cols[0].trimmingCharacters(in: .whitespaces)
            let storeNumber = cols[1].trimmingCharacters(in: .whitespaces)
            // Area is optional for backward compatibility — stores
            // without an area will appear to every AM regardless of
            // the AM's area. This prevents a partial stores.csv from
            // locking everyone out while the column is being added.
            let area = cols.count >= 3 ? cols[2].trimmingCharacters(in: .whitespaces) : ""
            // shortName is also optional. When present it's used in
            // compact UI; when absent the caller falls back to the
            // full `store` name (see Store.displayName).
            let shortName = cols.count >= 4 ? cols[3].trimmingCharacters(in: .whitespaces) : ""

            guard !store.isEmpty, !storeNumber.isEmpty else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "store or storeNumber is empty")
            }
            result.append(ParsedStore(store: store,
                                      storeNumber: storeNumber,
                                      area: area,
                                      shortName: shortName))
        }
        return result
    }

    @MainActor
    private func applyAtomicReplaceStores(parsed: [ParsedStore], container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        try context.delete(model: Store.self)
        for s in parsed {
            context.insert(Store(store: s.store,
                                 storeNumber: s.storeNumber,
                                 area: s.area,
                                 shortName: s.shortName))
        }
        try context.save()
        return parsed.count
    }

    // MARK: Territory managers sync
    //
    // CSV format expected (first row is header):
    //   territory,email
    //   East,east.tm@jacent.com
    //   West,west.tm@jacent.com

    struct ParsedTerritoryManager {
        let territory: String
        let email: String
    }

    func syncTerritoryManagers(into container: ModelContainer) async -> TerritoryManagerSync {
        let startURL = sourceURL.absoluteString
        do {
            let csv = try await fetchCSV()
            let parsed = try parseTerritoryManagers(csv: csv)
            guard !parsed.isEmpty else { throw SyncError.emptyTerritoryManagers }
            let count = try await applyAtomicReplaceTerritoryManagers(parsed: parsed, container: container)
            return TerritoryManagerSync(managerCount: count, sourceUrl: startURL, status: .success)
        } catch {
            return TerritoryManagerSync(
                managerCount: 0,
                sourceUrl: startURL,
                status: .failed,
                errorMessage: String(describing: error)
            )
        }
    }

    private func parseTerritoryManagers(csv: String) throws -> [ParsedTerritoryManager] {
        var result: [ParsedTerritoryManager] = []
        let lines = csv.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw SyncError.emptyTerritoryManagers }

        for (idx, rawLine) in lines.enumerated() where idx > 0 {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard cols.count >= 2 else {
                throw SyncError.malformedCSV(
                    line: idx + 1,
                    reason: "expected 2 columns: territory, email"
                )
            }
            let territory = cols[0].trimmingCharacters(in: .whitespaces)
            let email = cols[1].trimmingCharacters(in: .whitespaces)

            guard !territory.isEmpty, !email.isEmpty else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "territory or email is empty")
            }
            result.append(ParsedTerritoryManager(territory: territory, email: email))
        }
        return result
    }

    @MainActor
    private func applyAtomicReplaceTerritoryManagers(parsed: [ParsedTerritoryManager], container: ModelContainer) async throws -> Int {
        let context = ModelContext(container)
        try context.delete(model: TerritoryManager.self)
        for tm in parsed {
            context.insert(TerritoryManager(territory: tm.territory, email: tm.email))
        }
        try context.save()
        return parsed.count
    }
}

// MARK: - Audio service (buzzer)

// Two distinct sounds: a short confirm chirp on a successful scan,
// and an attention-grabbing buzzer when the running total crosses the
// $149.99 hard limit or a UPC is not found.
//
// Uses AVAudioPlayer with synthesized PCM tones rather than iOS system
// sounds. System sounds have proven unreliable across iOS versions —
// some IDs silently fail on iOS 17/18 depending on focus mode, ringer
// state, and audio routing. Synthesized tones are self-contained and
// play consistently as long as the audio session is active.
final class AudioService {
    static let shared = AudioService()

    private var confirmPlayer: AVAudioPlayer?
    private var buzzerPlayer: AVAudioPlayer?

    private init() {
        // .playback means "this app plays audible audio content" — iOS
        // treats this seriously and won't silently drop our output. It
        // does respect the ringer switch for ringing-style sounds, but
        // AVAudioPlayer with .playback plays regardless of the ringer.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        // Pre-build the two players so the first scan doesn't lag.
        confirmPlayer = makeTonePlayer(frequency: 1800, duration: 0.08, volume: 0.7)
        buzzerPlayer = makeTonePlayer(frequency: 380, duration: 0.35, volume: 0.9)
        confirmPlayer?.prepareToPlay()
        buzzerPlayer?.prepareToPlay()
    }

    func playScanConfirm() {
        confirmPlayer?.currentTime = 0
        confirmPlayer?.play()
    }

    func playOverLimitBuzzer() {
        buzzerPlayer?.currentTime = 0
        buzzerPlayer?.play()
        // Pair with haptic so the AM feels it even in a loud store.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    func playNotFound() {
        buzzerPlayer?.currentTime = 0
        buzzerPlayer?.play()
    }

    // Builds an AVAudioPlayer that plays a sine wave tone at the given
    // frequency, duration, and volume. Uses an in-memory WAV blob so
    // there's no bundled file dependency.
    private func makeTonePlayer(frequency: Double, duration: Double, volume: Float) -> AVAudioPlayer? {
        let sampleRate = 44100.0
        let sampleCount = Int(duration * sampleRate)
        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)

        // Short linear fade-in/out (5ms each side) to prevent clicks on
        // waveform start/end — rectangular cutoff produces a clicky pop.
        let fadeSamples = Int(0.005 * sampleRate)

        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let envelope: Double
            if i < fadeSamples {
                envelope = Double(i) / Double(fadeSamples)
            } else if i > sampleCount - fadeSamples {
                envelope = Double(sampleCount - i) / Double(fadeSamples)
            } else {
                envelope = 1.0
            }
            let sample = sin(2.0 * .pi * frequency * t) * envelope * 0.8
            samples.append(Int16(sample * Double(Int16.max)))
        }

        // Build WAV header + PCM data.
        let byteRate = Int(sampleRate) * 2  // mono, 16-bit
        let dataSize = samples.count * 2
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(UInt32(36 + dataSize).littleEndianData)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(UInt32(16).littleEndianData)       // PCM chunk size
        wav.append(UInt16(1).littleEndianData)        // format = PCM
        wav.append(UInt16(1).littleEndianData)        // mono
        wav.append(UInt32(sampleRate).littleEndianData)
        wav.append(UInt32(byteRate).littleEndianData)
        wav.append(UInt16(2).littleEndianData)        // block align
        wav.append(UInt16(16).littleEndianData)       // bits per sample
        wav.append("data".data(using: .ascii)!)
        wav.append(UInt32(dataSize).littleEndianData)
        samples.withUnsafeBufferPointer { buf in
            wav.append(buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: dataSize) { ptr in
                Data(bytes: ptr, count: dataSize)
            })
        }

        let player = try? AVAudioPlayer(data: wav)
        player?.volume = volume
        return player
    }
}

// Little-endian byte helpers for WAV header construction.
private extension UInt16 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
private extension UInt32 {
    var littleEndianData: Data {
        var v = self.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}

// MARK: - Launch coordinator & onboarding

// Root gate: picks between the onboarding screens and the main app.
// The decision is driven by two signals:
//   1. Is there a local AreaManager roster? (SwiftData fetchCount)
//   2. Has the AM selected who they are? (@AppStorage)
// Either missing signal holds the user on the corresponding onboarding
// screen. Once both are satisfied, RootTabView takes over.
struct LaunchCoordinator: View {
    @Environment(\.modelContext) private var context
    @Environment(ScanSessionStore.self) private var store
    @AppStorage("currentEmployeeNumber") private var currentEmployeeNumber: String = ""

    @Query private var managers: [AreaManager]

    var body: some View {
        Group {
            if managers.isEmpty {
                LoadingRosterView()
            } else if currentEmployeeNumber.isEmpty {
                AMPickerView { selected in
                    currentEmployeeNumber = selected.employeeNumber
                    store.currentEmployeeNumber = selected.employeeNumber
                }
            } else {
                RootTabView()
                    .onAppear { store.currentEmployeeNumber = currentEmployeeNumber }
            }
        }
    }
}

// Shown while the roster syncs on first launch, or when a retry is
// needed after a failure. If the fetch succeeds, the LaunchCoordinator's
// @Query will repopulate and this view will dismiss naturally.
struct LoadingRosterView: View {
    @Environment(\.modelContext) private var context
    @State private var coordinator = RosterSyncCoordinator.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 42))
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text("AM Credit Tracker").font(.title3).fontWeight(.medium)
            Text("Loading your area manager roster from Google Drive.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            contentForState
            Spacer()
        }
    }

    @ViewBuilder
    private var contentForState: some View {
        switch coordinator.state {
        case .idle, .syncing:
            ProgressView()
                .controlSize(.large)
            Text("Syncing…").font(.caption).foregroundStyle(.tertiary)
        case .succeeded:
            // Roster is in SwiftData — LaunchCoordinator's @Query will
            // pick it up on the next render tick. Nothing to do here.
            ProgressView()
        case .failed(let message):
            VStack(spacing: 12) {
                Text("Couldn't load roster")
                    .font(.subheadline).fontWeight(.medium).foregroundStyle(.red)
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Try again") {
                    Task { await retry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func retry() async {
        let container = context.container
        await RosterSyncCoordinator.shared.run(container: container)
    }
}

// AM picker — grouped by territory then area, searchable, with the
// selected row highlighted and a sticky "Continue as X" button at the
// bottom. Completing this flow sets @AppStorage so subsequent launches
// skip straight to the main app.
struct AMPickerView: View {
    let onSelect: (AreaManager) -> Void

    @Query(sort: [
        SortDescriptor(\AreaManager.territory),
        SortDescriptor(\AreaManager.area),
        SortDescriptor(\AreaManager.lastName)
    ]) private var allManagers: [AreaManager]

    @State private var search: String = ""
    @State private var selected: AreaManager?
    @State private var showWelcome = false

    private var filtered: [AreaManager] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allManagers }
        return allManagers.filter {
            $0.firstName.lowercased().contains(q)
            || $0.lastName.lowercased().contains(q)
            || $0.employeeNumber.lowercased().contains(q)
        }
    }

    private var grouped: [(header: String, managers: [AreaManager])] {
        let dict = Dictionary(grouping: filtered) { "\($0.territory) · \($0.area)" }
        return dict.keys.sorted().map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach(grouped, id: \.header) { group in
                        Section(group.header) {
                            ForEach(group.managers) { am in
                                Button {
                                    selected = am
                                } label: {
                                    HStack {
                                        Text(am.fullName).foregroundStyle(.primary)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .listRowBackground(
                                    selected?.employeeNumber == am.employeeNumber
                                    ? Color.accentColor.opacity(0.12) : Color(.systemBackground)
                                )
                            }
                        }
                    }
                }
                .searchable(text: $search, prompt: "Search by name")
                .listStyle(.insetGrouped)

                if let selected {
                    VStack(spacing: 0) {
                        Divider()
                        Button {
                            showWelcome = true
                        } label: {
                            Text("Continue as \(selected.fullName)")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                    }
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("Who's using this device?")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showWelcome) {
                if let selected {
                    WelcomeView(manager: selected) {
                        onSelect(selected)
                        showWelcome = false
                    }
                }
            }
        }
    }
}

// Shown once after AM selection to reinforce the audit-log attribution.
// Tapping "Start scanning" commits the selection via the picker's callback.
struct WelcomeView: View {
    let manager: AreaManager
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Welcome, \(manager.firstName)")
                .font(.title3).fontWeight(.medium)
            Text("You're signed in as the area manager for \(manager.area). Your scans will be tagged with your employee number in the audit log.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 8) {
                LabeledContent("Territory", value: manager.territory)
                LabeledContent("Area", value: manager.area)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 32)

            Button("Start scanning", action: onStart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)

            Text("You can change AMs later in Settings")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .presentationDetents([.large])
    }
}

// MARK: - Root tab view

struct RootTabView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

// MARK: - Scan view

struct ScanView: View {
    @Environment(ScanSessionStore.self) private var store
    @Environment(\.modelContext) private var context

    // Keyboard-wedge scanner input flows through this field. Keep it
    // focused so the scanner's keystrokes (+ trailing return) land here.
    @State private var scanBuffer: String = ""
    @FocusState private var inputFocused: Bool

    @State private var showManualOverride = false
    @State private var missingUPC: String = ""
    @State private var showSubmitConfirm = false
    @State private var showCamera = false
    @State private var editMode: EditMode = .inactive
    @State private var selectedItems: Set<UUID> = []

    // Camera-facing state so the camera view can show a 'not found'
    // flash when a scanned UPC isn't in the catalog.
    @State private var cameraNotFoundUPC: String?
    // Reason text accompanying cameraNotFoundUPC — distinguishes between
    // "not in catalog" and "wrong store" cases.
    @State private var cameraNotFoundReason: String?

    // Error message shown in the manual-entry path when a scan is rejected
    // because of store mismatch (doesn't go through the override sheet).
    @State private var lastScanErrorMessage: String?

    // Selected store and store number persist across launches. AMs
    // typically spend a full day at one store, so remembering the last
    // selection is a kindness. Empty strings mean "not yet selected."
    @AppStorage("selectedStore") private var selectedStore: String = ""
    @AppStorage("selectedStoreNumber") private var selectedStoreNumber: String = ""

    // Signed-in AM's employee number. Used to scope the store picker
    // to this AM's area (a Seattle-North AM only sees Seattle-North
    // stores — AMs have both a broader 'territory' and a specific 'area',
    // and stores partition by area).
    @AppStorage("currentEmployeeNumber") private var currentEmployeeNumber: String = ""
    @Query private var allManagers: [AreaManager]
    @Query private var territoryManagers: [TerritoryManager]

    // Resolve the signed-in AM's area, or "" if not yet signed in or
    // not found in the roster. Empty string = no area filter, all
    // stores visible (fail-open rather than fail-closed).
    private var currentAMArea: String {
        guard !currentEmployeeNumber.isEmpty else { return "" }
        return allManagers.first { $0.employeeNumber == currentEmployeeNumber }?.area ?? ""
    }

    // The full AreaManager record for the signed-in AM.
    private var currentAM: AreaManager? {
        guard !currentEmployeeNumber.isEmpty else { return nil }
        return allManagers.first { $0.employeeNumber == currentEmployeeNumber }
    }

    // AM's email for the CC line, or nil if not on file. When nil the
    // approval email is sent without a CC.
    private var currentAMEmail: String? {
        guard let am = currentAM, !am.email.isEmpty else { return nil }
        return am.email
    }

    // Territory manager email for the signed-in AM's territory, or nil
    // if not on file. When nil the submit sheet shows an error message
    // instead of the "open email draft" button.
    private var territoryManagerEmail: String? {
        guard let am = currentAM, !am.territory.isEmpty else { return nil }
        let match = territoryManagers.first { $0.territory == am.territory }
        guard let email = match?.email, !email.isEmpty else { return nil }
        return email
    }

    private func buildEmailSubject() -> String {
        let total = formatCurrencyForEmail(store.subtotal)
        return "Credit approval request: \(selectedStore) #\(selectedStoreNumber) — \(total)"
    }

    private func buildEmailBody() -> String {
        var lines: [String] = []
        lines.append("Hi,")
        lines.append("")
        lines.append("I'm requesting written approval for a credit that exceeds the $149.99 limit.")
        lines.append("")
        lines.append("SESSION DETAILS")
        lines.append("---------------")
        if let am = currentAM {
            lines.append("Area Manager: \(am.fullName) (#\(am.employeeNumber))")
            lines.append("Territory: \(am.territory)")
            lines.append("Area: \(am.area)")
        } else {
            lines.append("Area Manager: [unassigned]")
        }
        lines.append("Store: \(selectedStore)")
        lines.append("Store number: \(selectedStoreNumber)")
        lines.append("Date: \(formattedNow())")
        lines.append("")
        lines.append("LINE ITEMS")
        lines.append("----------")
        var running: Decimal = 0
        for (idx, item) in store.items.enumerated() {
            running += item.lineTotal
            let qty = item.quantity > 1 ? "\(item.quantity) × " : ""
            let line = "\(idx + 1). \(qty)\(item.name) @ \(formatCurrencyForEmail(item.price)) = \(formatCurrencyForEmail(item.lineTotal))   (running: \(formatCurrencyForEmail(running)))"
            lines.append(line)
            lines.append("   UPC: \(item.upc)")
            if item.manualOverride {
                lines.append("   [manual override]\(item.overrideNote.map { " — \($0)" } ?? "")")
            }
        }
        lines.append("")
        lines.append("TOTAL")
        lines.append("-----")
        let totalUnits = store.items.reduce(0) { $0 + $1.quantity }
        lines.append("Items: \(store.items.count) line\(store.items.count == 1 ? "" : "s") (\(totalUnits) unit\(totalUnits == 1 ? "" : "s"))")
        lines.append("Total: \(formatCurrencyForEmail(store.subtotal))")
        lines.append("Limit: \(formatCurrencyForEmail(ScanSessionStore.hardLimit))")
        lines.append("Over limit by: \(formatCurrencyForEmail(store.subtotal - ScanSessionStore.hardLimit))")
        lines.append("")
        lines.append("Please reply with written approval so I can proceed.")
        lines.append("")
        lines.append("Thanks,")
        if let am = currentAM {
            lines.append(am.fullName)
        }
        return lines.joined(separator: "\n")
    }

    private func formatCurrencyForEmail(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }

    private func formattedNow() -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: .now)
    }

    // Drive the empty-catalog and empty-stores banners. When either is
    // empty, scanning will fail — show explicit warnings so the AM knows
    // to sync instead of assuming every product is legitimately missing.
    @Query private var products: [Product]
    @Query private var storesData: [Store]
    @State private var catalogCoordinator = CatalogSyncCoordinator.shared
    @State private var storeCoordinator = StoreSyncCoordinator.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if storesData.isEmpty {
                    emptyStoresBanner
                }
                if products.isEmpty {
                    emptyCatalogBanner
                } else if isCatalogSyncing {
                    catalogSyncingIndicator
                }
                if !storesData.isEmpty {
                    storePickerBar
                }
                statusBar
                scanField
                if let msg = lastScanErrorMessage {
                    scanErrorBanner(message: msg)
                }
                itemsList
                actionBar
            }
            .environment(\.editMode, $editMode)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Credit limit tracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.items.isEmpty {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation {
                                if editMode.isEditing {
                                    editMode = .inactive
                                    selectedItems.removeAll()
                                } else {
                                    editMode = .active
                                }
                            }
                        }
                    }
                }
            }
            .onAppear {
                inputFocused = true
                validateStoreSelectionForCurrentAM()
            }
            .sheet(isPresented: $showManualOverride) {
                ManualPriceSheet(upc: missingUPC) { override in
                    addManualItem(override)
                }
            }
            .sheet(isPresented: $showSubmitConfirm) {
                SubmitSheet(
                    isOverLimit: store.isOverLimit,
                    subtotal: store.subtotal,
                    store: selectedStore,
                    storeNumber: selectedStoreNumber,
                    itemCount: store.items.count,
                    tmEmail: territoryManagerEmail,
                    amEmail: currentAMEmail,
                    emailSubject: buildEmailSubject(),
                    emailBody: buildEmailBody()
                ) {
                    submit()
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraScannerView(notFoundUPC: cameraNotFoundUPC, notFoundReason: cameraNotFoundReason) { upc in
                    return handleScan(upc)
                }
            }
        }
    }

    private var emptyCatalogBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(isCatalogSyncing ? "Loading product catalog…" : "Product catalog is empty")
                    .font(.subheadline).fontWeight(.medium)
                Text(isCatalogSyncing
                     ? "Scans will fail until this finishes. Hang tight."
                     : "Every scan will say 'not in catalog' until the catalog is synced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isCatalogSyncing {
                Button("Sync") {
                    Task {
                        let container = context.container
                        await CatalogSyncCoordinator.shared.run(container: container)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    private var isCatalogSyncing: Bool {
        if case .syncing = catalogCoordinator.state { return true }
        return false
    }

    // Thin strip shown while a catalog sync is in progress but we
    // already have products — the AM can keep scanning with the old
    // catalog; the indicator just lets them know an update is coming.
    private var catalogSyncingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Syncing product catalog…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground))
    }

    private var isStoreSyncing: Bool {
        if case .syncing = storeCoordinator.state { return true }
        return false
    }

    // Shown when no Store rows exist at all. Without stores the pickers
    // can't populate, so scanning will fail. Offer a direct sync action.
    private var emptyStoresBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(isStoreSyncing ? "Loading stores…" : "Store list is empty")
                    .font(.subheadline).fontWeight(.medium)
                Text(isStoreSyncing
                     ? "Store picker will populate when this finishes."
                     : "You need stores before you can scan. Tap Sync to download them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isStoreSyncing {
                Button("Sync") {
                    Task {
                        let container = context.container
                        await StoreSyncCoordinator.shared.run(container: container)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    // Two dependent pickers: store (retailer chain) and store number.
    // Picking a store filters the store-number picker to just the
    // numbered locations for that chain. Both pickers are further
    // scoped to the signed-in AM's area so AMs only see the stores
    // they actually cover.
    private var storePickerBar: some View {
        let storeService = StoreService(context: context)
        let area = currentAMArea
        let storeNames = storeService.distinctStoreNames(in: area)
        let availableNumbers = selectedStore.isEmpty
            ? []
            : storeService.storeNumbers(for: selectedStore, in: area)

        return HStack(spacing: 10) {
            // Store name picker
            Menu {
                ForEach(storeNames, id: \.self) { name in
                    Button {
                        if selectedStore != name {
                            selectedStore = name
                            // Reset store number when the chain changes —
                            // the previous number won't apply to the new
                            // chain, and we want the AM to pick explicitly.
                            selectedStoreNumber = ""
                        }
                    } label: {
                        HStack {
                            Text(name)
                            if selectedStore == name {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedStore.isEmpty ? "Store" : selectedStore)
                        .fontWeight(selectedStore.isEmpty ? .regular : .medium)
                        .foregroundStyle(selectedStore.isEmpty ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(!store.items.isEmpty)
            .opacity(store.items.isEmpty ? 1.0 : 0.5)

            // Store number picker, dependent on the selected store
            Menu {
                ForEach(availableNumbers, id: \.self) { num in
                    Button {
                        selectedStoreNumber = num
                    } label: {
                        HStack {
                            Text(num)
                            if selectedStoreNumber == num {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedStoreNumber.isEmpty ? "Store #" : "#\(selectedStoreNumber)")
                        .fontWeight(selectedStoreNumber.isEmpty ? .regular : .medium)
                        .foregroundStyle(selectedStoreNumber.isEmpty ? .secondary : .primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(selectedStore.isEmpty || availableNumbers.isEmpty || !store.items.isEmpty)
            .opacity((selectedStore.isEmpty || !store.items.isEmpty) ? 0.5 : 1.0)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func scanErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
            Text(message)
                .font(.caption).foregroundStyle(.primary)
            Spacer()
            Button {
                lastScanErrorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
        .task(id: message) {
            // Auto-dismiss after 4 seconds so stale messages don't linger.
            try? await Task.sleep(for: .seconds(4))
            if lastScanErrorMessage == message {
                lastScanErrorMessage = nil
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Subtotal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Limit \(Self.currency(ScanSessionStore.hardLimit))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Self.currency(store.subtotal))
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(store.isOverLimit ? .red : .primary)
            ProgressView(value: store.percentOfLimit)
                .tint(progressTint)
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(statusTint)
        }
        .padding()
        .background(statusBackground)
    }

    private var scanField: some View {
        HStack {
            TextField("Scan or type UPC…", text: $scanBuffer)
                .textFieldStyle(.roundedBorder)
                .focused($inputFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { handleScan() }
            Button("Add") { handleScan() }
                .disabled(scanBuffer.isEmpty)
            Button {
                if editMode.isEditing {
                    withAnimation {
                        editMode = .inactive
                        selectedItems.removeAll()
                    }
                }
                showCamera = true
            } label: {
                Image(systemName: "camera.viewfinder")
                    .font(.title3)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Scan with camera")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var itemsList: some View {
        List(selection: $selectedItems) {
            ForEach(store.items) { item in
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.name).font(.subheadline).fontWeight(.medium)
                            if item.manualOverride {
                                Text("manual")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                        HStack(spacing: 6) {
                            Text(item.upc).font(.caption2).monospaced().foregroundStyle(.tertiary)
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text("\(Self.currency(item.price)) ea").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("\(item.quantity)")
                                .font(.subheadline).fontWeight(.medium)
                                .monospacedDigit()
                                .frame(minWidth: 24, alignment: .trailing)
                            if !editMode.isEditing {
                                Stepper(
                                    "Quantity",
                                    value: Binding(
                                        get: { item.quantity },
                                        set: { store.setQuantity(id: item.id, quantity: $0) }
                                    ),
                                    in: 1...999
                                )
                                .labelsHidden()
                            }
                        }
                        Text(Self.currency(item.lineTotal))
                            .font(.subheadline).fontWeight(.medium)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.remove(item)
                    } label: { Label("Remove", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if editMode.isEditing {
                Button(selectedItems.count == store.items.count ? "Deselect all" : "Select all") {
                    if selectedItems.count == store.items.count {
                        selectedItems.removeAll()
                    } else {
                        selectedItems = Set(store.items.map { $0.id })
                    }
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(role: .destructive) {
                    deleteSelected()
                } label: {
                    Text(selectedItems.isEmpty ? "Delete" : "Delete (\(selectedItems.count))")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedItems.isEmpty)
            } else {
                Button("Clear") { store.clear() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(store.isOverLimit ? "Request approval" : "Submit credit") {
                    showSubmitConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isOverLimit ? .orange : .accentColor)
                .disabled(store.items.isEmpty)
            }
        }
        .padding()
    }

    private func deleteSelected() {
        for id in selectedItems {
            if let item = store.items.first(where: { $0.id == id }) {
                store.remove(item)
            }
        }
        selectedItems.removeAll()
        withAnimation {
            editMode = .inactive
        }
    }

    // Clear the saved store selection if the signed-in AM's area
    // no longer includes it. Handles the "AM switched accounts" case —
    // otherwise a Seattle-North AM signing in after a Seattle-South AM
    // would be left with a stale Seattle-South store pre-selected.
    private func validateStoreSelectionForCurrentAM() {
        guard !selectedStore.isEmpty else { return }
        let area = currentAMArea
        let storeService = StoreService(context: context)
        let allowedStores = storeService.distinctStoreNames(in: area)
        if !allowedStores.contains(selectedStore) {
            selectedStore = ""
            selectedStoreNumber = ""
            return
        }
        let allowedNumbers = storeService.storeNumbers(for: selectedStore, in: area)
        if !selectedStoreNumber.isEmpty && !allowedNumbers.contains(selectedStoreNumber) {
            selectedStoreNumber = ""
        }
    }

    // MARK: scan handling

    // Called from three places: the Add button, the text field's submit
    // action, and the camera view's callback. Passing nil pulls the UPC
    // from scanBuffer (the keyboard-wedge path); passing a String uses it
    // directly (the camera path). Returns a ScanResult so the camera
    // view can decide whether to auto-close after success.
    @discardableResult
    private func handleScan(_ scannedUPC: String? = nil) -> ScanResult {
        let upc: String
        if let scannedUPC {
            upc = scannedUPC.trimmingCharacters(in: .whitespaces)
        } else {
            upc = scanBuffer.trimmingCharacters(in: .whitespaces)
            scanBuffer = ""
            inputFocused = true
        }
        guard !upc.isEmpty else { return .notFound }

        // Can't scan without both a store and store number selected.
        // The catalog lookup uses the store (retailer chain); the store
        // number is recorded on the submitted session for audit.
        guard !selectedStore.isEmpty, !selectedStoreNumber.isEmpty else {
            AudioService.shared.playNotFound()
            let reason = "Select a store and store number first"
            if showCamera {
                cameraNotFoundUPC = upc
                cameraNotFoundReason = reason
            } else {
                lastScanErrorMessage = reason
            }
            return .notFound
        }

        // If we're in edit mode when a scan arrives, the AM has moved on
        // from editing. Exit cleanly so the new item shows in the normal
        // list view, not as an unselected row in the selection list.
        if editMode.isEditing {
            withAnimation {
                editMode = .inactive
                selectedItems.removeAll()
            }
        }

        // Propagate the current store number to the session store so
        // that when the AM submits, the session record carries the
        // correct store number for audit.
        store.currentStoreNumber = selectedStoreNumber

        let catalog = CatalogService(context: context)
        let result = catalog.lookup(upc: upc, store: selectedStore)

        switch result {
        case .found(let product):
            store.add(.init(
                upc: product.upc,
                name: product.name,
                price: product.price,
                manualOverride: false,
                overrideNote: nil,
                scannedAt: .now
            ))
            cameraNotFoundUPC = nil
            cameraNotFoundReason = nil
            return .added

        case .wrongStore(let availableAt):
            AudioService.shared.playNotFound()
            missingUPC = upc
            let storesList = availableAt.joined(separator: ", ")
            let reason = availableAt.count == 1
                ? "Not in this store — available at \(storesList)"
                : "Not in this store — available at: \(storesList)"
            if showCamera {
                cameraNotFoundUPC = upc
                cameraNotFoundReason = reason
            } else {
                lastScanErrorMessage = reason
            }
            return .notFound

        case .notInCatalog:
            AudioService.shared.playNotFound()
            missingUPC = upc
            if showCamera {
                cameraNotFoundUPC = upc
                cameraNotFoundReason = "Not in catalog"
            } else {
                showManualOverride = true
            }
            return .notFound
        }
    }

    private func addManualItem(_ override: ManualOverride) {
        store.add(.init(
            upc: override.upc,
            name: override.name,
            price: override.price,
            manualOverride: true,
            overrideNote: override.note,
            scannedAt: .now
        ))
    }

    private func submit() {
        let catalog = CatalogService(context: context)
        let lastSync = catalog.lastSyncedAt()
        // Both under-limit and over-limit submits reach here. Under-limit
        // goes straight to audit. Over-limit arrives here only after the
        // AM has successfully composed the approval email (the SubmitSheet
        // gates it). The session's status will reflect which path it was.
        do {
            try store.submit(into: context, catalogSyncedAt: lastSync)
            showSubmitConfirm = false
        } catch {
            print("Submit failed: \(error)")
        }
    }

    // MARK: presentation helpers

    private var progressTint: Color {
        if store.isOverLimit { return .red }
        if store.isApproachingLimit { return .orange }
        return .green
    }

    private var statusTint: Color {
        if store.isOverLimit { return .red }
        if store.isApproachingLimit { return .orange }
        return .green
    }

    private var statusMessage: String {
        if store.isOverLimit { return "Over limit — written approval required" }
        if store.isApproachingLimit { return "Approaching limit" }
        return "Within limit"
    }

    private var statusBackground: Color {
        if store.isOverLimit { return .red.opacity(0.08) }
        if store.isApproachingLimit { return .orange.opacity(0.08) }
        return Color(.secondarySystemBackground)
    }

    static func currency(_ d: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: d as NSDecimalNumber) ?? "$0.00"
    }
}

// MARK: - Manual override sheet

struct ManualOverride {
    let upc: String
    let name: String
    let price: Decimal
    let note: String?
}

struct ManualPriceSheet: View {
    let upc: String
    let onSave: (ManualOverride) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var priceText: String = ""
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("UPC") {
                    Text(upc).monospaced()
                }
                Section {
                    Text("This item will be flagged as a manual override in the audit log.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } header: { Text("Heads up") }
                Section("Product") {
                    TextField("Product name", text: $name)
                    TextField("Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }
                Section("Note (optional)") {
                    TextField("e.g. new SKU, confirmed with store", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("UPC not found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && parsedPrice != nil
    }

    private var parsedPrice: Decimal? {
        let d = NSDecimalNumber(string: priceText)
        return d == .notANumber ? nil : d as Decimal
    }

    private func save() {
        guard let price = parsedPrice else { return }
        onSave(ManualOverride(
            upc: upc,
            name: name.trimmingCharacters(in: .whitespaces),
            price: price,
            note: note.isEmpty ? nil : note
        ))
        dismiss()
    }
}

// MARK: - Submit confirm sheet

struct SubmitSheet: View {
    let isOverLimit: Bool
    let subtotal: Decimal
    let store: String
    let storeNumber: String
    let itemCount: Int
    let tmEmail: String?
    let amEmail: String?
    let emailSubject: String
    let emailBody: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showMailComposer = false
    @State private var mailResult: MFMailComposeResult?
    @State private var showNoMailAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if isOverLimit {
                    overLimitBody
                } else {
                    normalBody
                }
            }
            .padding()
            .navigationTitle(isOverLimit ? "Approval required" : "Submit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showMailComposer) {
                if let tm = tmEmail {
                    MailComposerView(
                        to: [tm],
                        cc: amEmail.map { [$0] } ?? [],
                        subject: emailSubject,
                        body: emailBody,
                        result: $mailResult
                    )
                }
            }
            .onChange(of: mailResult) { _, newValue in
                guard let r = newValue else { return }
                switch r {
                case .sent, .saved:
                    // Persist the session locally so we have a record
                    // even though the final approval happens via email.
                    onConfirm()
                    dismiss()
                case .cancelled, .failed:
                    // AM cancelled or mail failed — don't persist,
                    // let them try again.
                    break
                @unknown default:
                    break
                }
                // Reset so a subsequent send can re-trigger onChange.
                mailResult = nil
            }
            .alert("No mail account configured", isPresented: $showNoMailAlert) {
                Button("OK") {}
            } message: {
                Text("Your device needs a configured mail account (Mail app) to send the approval email. Set one up in Settings → Mail.")
            }
        }
    }

    private var normalBody: some View {
        VStack(spacing: 16) {
            Text("Submit credit request?")
                .font(.title3).fontWeight(.medium)
            VStack(spacing: 4) {
                Text(formatCurrency(subtotal))
                    .font(.system(size: 34, weight: .medium))
                Text("\(itemCount) item\(itemCount == 1 ? "" : "s") at \(store) #\(storeNumber)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("This will record the session to the audit log and clear the scan list.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Confirm and submit") {
                onConfirm()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var overLimitBody: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            VStack(spacing: 4) {
                Text(formatCurrency(subtotal))
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.red)
                Text("\(itemCount) item\(itemCount == 1 ? "" : "s") at \(store) #\(storeNumber)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("This credit is over the $149.99 limit and requires written approval from the Territory Manager.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let tm = tmEmail {
                VStack(spacing: 2) {
                    Text("The email will be sent to:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(tm)
                        .font(.caption).fontWeight(.medium)
                    if let am = amEmail {
                        Text("CC: \(am)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Button {
                    if MFMailComposeViewController.canSendMail() {
                        showMailComposer = true
                    } else {
                        showNoMailAlert = true
                    }
                } label: {
                    Label("Open email draft", systemImage: "envelope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Text("No Territory Manager email on file for this territory. Contact your Area Manager or check that territory_managers.csv is synced.")
                    .font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        }
    }

    private func formatCurrency(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}

// UIKit wrapper around MFMailComposeViewController so SwiftUI can present it.
struct MailComposerView: UIViewControllerRepresentable {
    let to: [String]
    let cc: [String]
    let subject: String
    let body: String
    @Binding var result: MFMailComposeResult?

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(result: $result, dismiss: { dismiss() })
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(to)
        if !cc.isEmpty { vc.setCcRecipients(cc) }
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding var result: MFMailComposeResult?
        let dismiss: () -> Void

        init(result: Binding<MFMailComposeResult?>, dismiss: @escaping () -> Void) {
            self._result = result
            self.dismiss = dismiss
        }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            if let error = error {
                print("Mail compose error: \(error)")
                self.result = .failed
            } else {
                self.result = result
            }
            dismiss()
        }
    }
}

// MARK: - History, session detail, settings (stubs)

struct HistoryView: View {
    @Query(sort: \ScanSession.startedAt, order: .reverse) private var sessions: [ScanSession]
    // All stores are loaded once here and passed down as a lookup map
    // keyed by storeNumber. Avoids each HistoryRow issuing its own query.
    @Query private var stores: [Store]

    // storeNumber -> shortName label (first non-empty shortName wins).
    // Built once per body evaluation; cheap for the roster sizes we expect.
    private var shortNames: [String: String] {
        var map: [String: String] = [:]
        for s in stores where !s.shortName.isEmpty {
            if map[s.storeNumber] == nil {
                map[s.storeNumber] = s.shortName
            }
        }
        return map
    }

    var body: some View {
        NavigationStack {
            List(sessions) { session in
                NavigationLink(value: session.id) {
                    HistoryRow(session: session, storeShortNames: shortNames)
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
        }
    }
}

struct HistoryRow: View {
    let session: ScanSession
    // Lookup built by HistoryView. Missing keys → no shortname available,
    // fall back to the generic "Store #..." label.
    let storeShortNames: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .fontWeight(.medium)
                Spacer()
                Text(ScanView.currency(session.totalAmount))
                    .fontWeight(.medium)
                    .foregroundStyle(session.status == .overLimit ? .red : .primary)
            }
            HStack {
                Text(itemsSummary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                StatusPill(status: session.status)
            }
        }
        .padding(.vertical, 4)
    }

    // Items summary includes a compact store label when the session
    // has a storeNumber. Prefers the stores.csv `shortName` ("TGT #1842")
    // when one is mapped, otherwise falls back to "Store #1842" so rows
    // from older sessions or un-shortnamed stores still read cleanly.
    private var itemsSummary: String {
        let lines = session.items.count
        let units = session.items.reduce(0) { $0 + $1.quantity }
        let base = lines == units
            ? "\(lines) items"
            : "\(lines) items · \(units) units"
        guard let storeNumber = session.storeNumber, !storeNumber.isEmpty else {
            return base
        }
        let label = storeShortNames[storeNumber].map { "\($0) #\(storeNumber)" }
            ?? "Store #\(storeNumber)"
        return "\(base) · \(label)"
    }
}

struct StatusPill: View {
    let status: SessionStatus

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(Capsule())
    }

    private var label: String {
        switch status {
        case .active: "Active"
        case .submitted: "Submitted"
        case .abandoned: "Abandoned"
        case .overLimit: "Over limit"
        }
    }

    private var background: Color {
        switch status {
        case .submitted: .green.opacity(0.15)
        case .overLimit: .red.opacity(0.15)
        case .abandoned: .gray.opacity(0.15)
        case .active: .blue.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch status {
        case .submitted: .green
        case .overLimit: .red
        case .abandoned: .gray
        case .active: .blue
        }
    }
}

struct SessionDetailView: View {
    let sessionID: UUID
    @Query private var sessions: [ScanSession]
    @Query private var allManagers: [AreaManager]
    // Used to resolve the session's storeNumber to its retailer name
    // (e.g. "Target #1842") for the header label. Falls back to
    // "Store #1842" if no Store row matches the number.
    @Query private var allStores: [Store]

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _sessions = Query(filter: #Predicate<ScanSession> { $0.id == sessionID })
    }

    // Resolves a storeNumber to "<retailer> #<num>" using the synced
    // stores table, or falls back to "Store #<num>" when no match exists.
    private func storeLabel(for storeNumber: String) -> String {
        if let match = allStores.first(where: { $0.storeNumber == storeNumber }),
           !match.store.isEmpty {
            return "\(match.store) #\(storeNumber)"
        }
        return "Store #\(storeNumber)"
    }

    var body: some View {
        if let session = sessions.first {
            ScrollView {
                VStack(spacing: 0) {
                    headerSection(session: session)
                    if session.status == .overLimit {
                        overLimitBanner
                    }
                    lineItemsSection(session: session)
                    totalsSection(session: session)
                    metadataSection(session: session)
                }
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Session detail")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Session not found")
                    .font(.headline)
                Text("This session may have been deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sections

    private func headerSection(session: ScanSession) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text(formatCurrency(session.totalAmount))
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(session.status == .overLimit ? .red : .primary)
                Text(session.submittedAt ?? session.startedAt, format: .dateTime.month(.wide).day().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            StatusPill(status: session.status)

            // Store and AM attribution
            VStack(spacing: 2) {
                if let storeNumber = session.storeNumber, !storeNumber.isEmpty {
                    Text(storeLabel(for: storeNumber))
                        .font(.subheadline).fontWeight(.medium)
                }
                if let amName = amName(for: session.employeeNumber) {
                    Text(amName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Employee #\(session.employeeNumber)")
                    .font(.caption2).foregroundStyle(.tertiary).monospaced()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .background(Color(.systemBackground))
    }

    private var overLimitBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Required written approval")
                    .font(.subheadline).fontWeight(.medium)
                Text("This session exceeded the $149.99 credit limit. Approval email sent to Territory Manager at submission time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func lineItemsSection(session: ScanSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Line items")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)

            // Sort by scannedAt so the display order matches how the
            // AM scanned them in the session, not the insertion order
            // the SwiftData relationship happens to return.
            let sorted = session.items.sorted { $0.scannedAt < $1.scannedAt }
            VStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, item in
                    lineItemRow(item: item, index: idx + 1)
                    if idx < sorted.count - 1 {
                        Divider().padding(.leading, 20)
                    }
                }
            }
            .background(Color(.systemBackground))
        }
    }

    private func lineItemRow(item: ScannedItem, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                        .font(.subheadline).fontWeight(.medium)
                    if item.manualOverride {
                        Text("manual")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(item.upc)
                    .font(.caption2).monospaced()
                    .foregroundStyle(.tertiary)
                if let note = item.overrideNote, !note.isEmpty {
                    Text(note)
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if item.quantity > 1 {
                        Text("\(item.quantity) × \(formatCurrency(item.price))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(formatCurrency(item.price))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Text(formatCurrency(item.lineTotal))
                .font(.subheadline).fontWeight(.medium)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func totalsSection(session: ScanSession) -> some View {
        let totalUnits = session.items.reduce(0) { $0 + $1.quantity }
        return VStack(spacing: 0) {
            totalsRow(label: "Line items", value: "\(session.items.count)")
            Divider().padding(.leading, 20)
            totalsRow(label: "Total units", value: "\(totalUnits)")
            Divider().padding(.leading, 20)
            totalsRow(label: "Total", value: formatCurrency(session.totalAmount), emphasize: true)
        }
        .background(Color(.systemBackground))
        .padding(.top, 20)
    }

    private func totalsRow(label: String, value: String, emphasize: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasize ? .subheadline : .caption)
                .fontWeight(emphasize ? .medium : .regular)
                .foregroundStyle(emphasize ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(emphasize ? .subheadline : .caption)
                .fontWeight(emphasize ? .medium : .regular)
                .monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func metadataSection(session: ScanSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Audit metadata")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 8)
            VStack(spacing: 0) {
                metadataRow(label: "Session ID", value: session.id.uuidString)
                Divider().padding(.leading, 20)
                metadataRow(
                    label: "Scan started",
                    value: session.startedAt.formatted(date: .abbreviated, time: .shortened)
                )
                if let submitted = session.submittedAt {
                    Divider().padding(.leading, 20)
                    metadataRow(
                        label: "Submitted",
                        value: submitted.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let catalogDate = session.catalogSyncedAt {
                    Divider().padding(.leading, 20)
                    metadataRow(
                        label: "Catalog synced",
                        value: catalogDate.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                if let notes = session.notes, !notes.isEmpty {
                    Divider().padding(.leading, 20)
                    metadataRow(label: "Notes", value: notes)
                }
            }
            .background(Color(.systemBackground))
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption).monospaced()
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func amName(for employeeNumber: String) -> String? {
        allManagers.first { $0.employeeNumber == employeeNumber }?.fullName
    }

    private func formatCurrency(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US")
        return f.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var isSyncing = false
    @State private var lastSyncMessage: String = ""
    @State private var isStoreSyncing = false
    @State private var lastStoreSyncMessage: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Product catalog") {
                    // TODO: live sync status row + "Sync now" + "View log"
                    Button(isSyncing ? "Syncing…" : "Sync now") {
                        Task { await runSync() }
                    }
                    .disabled(isSyncing)
                    if !lastSyncMessage.isEmpty {
                        Text(lastSyncMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Stores") {
                    Button(isStoreSyncing ? "Syncing…" : "Sync now") {
                        Task { await runStoreSync() }
                    }
                    .disabled(isStoreSyncing)
                    if !lastStoreSyncMessage.isEmpty {
                        Text(lastStoreSyncMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Session") {
                    LabeledContent("Warn at", value: "90% ($134.99)")
                    LabeledContent("Hard limit", value: "$149.99")
                }
                Section("Source") {
                    LabeledContent("Type", value: "Google Drive")
                    LabeledContent("Access", value: "Anyone with link")
                }
                Section("Account") {
                    if let am = currentManager {
                        LabeledContent("Name", value: am.fullName)
                        LabeledContent("Employee #", value: am.employeeNumber)
                        LabeledContent("Territory", value: am.territory)
                        LabeledContent("Area", value: am.area)
                    } else {
                        Text("No AM selected").foregroundStyle(.secondary)
                    }
                    Button("Change area manager", role: .destructive) {
                        currentEmployeeNumber = ""
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    @AppStorage("currentEmployeeNumber") private var currentEmployeeNumber: String = ""
    @Query private var allManagers: [AreaManager]
    private var currentManager: AreaManager? {
        allManagers.first { $0.employeeNumber == currentEmployeeNumber }
    }

    private func runSync() async {
        isSyncing = true
        defer { isSyncing = false }
        // Google Drive share URL for catalog.csv.
        // Either share link format works — the SyncService normalizes it.
        guard let url = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n") else { return }
        let service = SyncService(sourceURL: url)
        let container = context.container
        let record = await service.sync(into: container)
        await MainActor.run {
            context.insert(record)
            try? context.save()
            lastSyncMessage = record.status == .success
                ? "Synced \(record.productCount) products."
                : "Sync failed: \(record.errorMessage ?? "unknown error")"
        }
    }

    private func runStoreSync() async {
        isStoreSyncing = true
        defer { isStoreSyncing = false }
        let container = context.container
        await StoreSyncCoordinator.shared.run(container: container)
        await MainActor.run {
            switch StoreSyncCoordinator.shared.state {
            case .succeeded(let count):
                lastStoreSyncMessage = "Synced \(count) stores."
            case .failed(let message):
                lastStoreSyncMessage = "Sync failed: \(message)"
            default:
                lastStoreSyncMessage = ""
            }
        }
    }
}

// MARK: - Camera scanner (fallback when no hand scanner available)

// Wraps Apple's DataScannerViewController (iOS 16+) in a UIViewController
// representable. Batch mode: stays open and calls onScan for each unique
// barcode detected until the AM taps Done.
//
// Requires Info.plist entry:
//   NSCameraUsageDescription: "Scan product barcodes when a hand scanner
//   isn't available."
//
// Supported symbologies match Apple's Vision framework: UPC-A, UPC-E,
// EAN-13, EAN-8, Code 128, Code 39, QR. Jacent products use UPC-A
// primarily — the extras cost nothing to leave enabled.
//
// UPC FORMAT FLEXIBILITY: DataScannerViewController can report a given
// barcode as either UPC-A (12 digits) or EAN-13 (13 digits with leading
// zero) depending on the device and scanner settings. Rather than
// normalize here, we pass the raw value through — CatalogService.lookup
// tries both formats against the catalog so matching works regardless
// of which representation the catalog uses.

// Result of handing a scanned UPC to the parent. Lets the camera decide
// what to do next — auto-close on success, keep scanning on not-found.
enum ScanResult {
    case added
    case notFound
}

struct CameraScannerView: View {
    let notFoundUPC: String?
    let notFoundReason: String?
    let onScan: (String) -> ScanResult

    @Environment(\.dismiss) private var dismiss
    @State private var lastScannedUPC: String?
    @State private var scanCount: Int = 0
    @State private var isSupported = DataScannerViewController.isSupported
        && DataScannerViewController.isAvailable

    var body: some View {
        ZStack(alignment: .bottom) {
            if isSupported {
                DataScannerRepresentable { upc in
                    handleDetection(upc)
                }
                .ignoresSafeArea()
            } else {
                // Older devices or unavailable hardware. Fall back to
                // a message — the AM can still use the text field.
                VStack(spacing: 12) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("Camera scanning unavailable")
                        .font(.headline)
                    Text("Your device doesn't support live barcode scanning. Please use a hand scanner or type the UPC manually.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding()
                }
                Spacer()
                if isSupported {
                    scanStatusBar
                }
            }
        }
    }

    private var scanStatusBar: some View {
        VStack(spacing: 4) {
            if let lastScannedUPC, notFoundUPC == lastScannedUPC {
                // Show the specific reason (not in catalog / wrong store /
                // no store selected) with the scanned UPC for context.
                Text(notFoundReason ?? "Not in catalog")
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Text(lastScannedUPC)
                    .font(.caption2).monospaced()
                    .foregroundStyle(.white.opacity(0.85))
            } else if let lastScannedUPC {
                Text("Added: \(lastScannedUPC)")
                    .font(.caption).monospaced()
                    .foregroundStyle(.white)
            } else {
                Text("Point at a barcode")
                    .font(.caption).foregroundStyle(.white)
            }
            Text("\(scanCount) scanned this session")
                .font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.55))
    }

    // Debounce: the DataScanner fires continuously while a barcode is in
    // view. We only want to register a scan once per unique code, with a
    // short cooldown so the AM can re-scan the same item intentionally.
    @State private var recentlyScanned: [String: Date] = [:]

    private func handleDetection(_ upc: String) {
        let trimmed = upc.trimmingCharacters(in: .whitespaces)
        let now = Date()
        if let last = recentlyScanned[trimmed], now.timeIntervalSince(last) < 2.0 {
            return
        }
        recentlyScanned[trimmed] = now
        lastScannedUPC = trimmed
        scanCount += 1
        // ScanSessionStore.add() or handleScan()'s not-found branch
        // plays the appropriate sound, so we don't double-chirp here.
        let result = onScan(trimmed)
        if result == .added {
            // Small delay so the AM briefly sees the "Added: [UPC]"
            // confirmation before the camera dismisses. Feels less
            // abrupt than closing instantly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                dismiss()
            }
        }
    }
}

// UIViewControllerRepresentable wrapping DataScannerViewController. This
// is a minimal bridge — Apple's scanner handles autofocus, highlighting
// detected codes, and low-light adaptation automatically.
struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onBarcode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.upce, .ean13, .ean8, .code128, .code39, .qr])
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onBarcode: onBarcode) }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onBarcode: (String) -> Void
        init(onBarcode: @escaping (String) -> Void) { self.onBarcode = onBarcode }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    onBarcode(payload)
                }
            }
        }
    }
}

// MARK: - Background refresh hook (optional)

// Register this task identifier in Info.plist under
// "Permitted background task scheduler identifiers":
//   com.jacent.amcredit.catalog-sync
//
// Then in your AppDelegate / App init:
//
//   BGTaskScheduler.shared.register(
//       forTaskWithIdentifier: "com.jacent.amcredit.catalog-sync",
//       using: nil
//   ) { task in
//       Task {
//           let url = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n")!
//           let svc = SyncService(sourceURL: url)
//           _ = await svc.sync(into: sharedContainer)
//           task.setTaskCompleted(success: true)
//       }
//   }
//
// And schedule it after successful foreground syncs:
//
//   let req = BGAppRefreshTaskRequest(identifier: "com.jacent.amcredit.catalog-sync")
//   req.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
//   try? BGTaskScheduler.shared.submit(req)
