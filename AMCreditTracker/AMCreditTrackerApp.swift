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
                AreaManagerSync.self
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
        // Run roster and catalog syncs in parallel. Roster blocks the UI
        // (LaunchCoordinator waits on it). Catalog runs non-blocking —
        // the UI loads immediately and the catalog populates when ready,
        // which means the AM can navigate and select their identity
        // while the product list downloads in the background.
        async let roster: Void = RosterSyncCoordinator.shared.run(container: container)
        async let catalog: Void = CatalogSyncCoordinator.shared.run(container: container)
        _ = await (roster, catalog)
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
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1rOFqR8IDo4lEJmT39tHtw7JsLggOauxf/view?usp=share_link")!

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
    private let sourceURL = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n/view?usp=share_link")!

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

// MARK: - Models (SwiftData)

@Model
final class Product {
    // UPC is the natural key — indexed for fast lookup during scans.
    @Attribute(.unique) var upc: String
    var name: String
    var price: Decimal
    var category: String?
    var lastUpdated: Date

    init(upc: String, name: String, price: Decimal, category: String? = nil, lastUpdated: Date = .now) {
        self.upc = upc
        self.name = name
        self.price = price
        self.category = category
        self.lastUpdated = lastUpdated
    }
}

@Model
final class AreaManager {
    @Attribute(.unique) var employeeNumber: String
    var firstName: String
    var lastName: String
    var territory: String   // broader grouping
    var area: String        // the AM's slice within a territory

    var fullName: String { "\(firstName) \(lastName)" }

    init(employeeNumber: String, firstName: String, lastName: String, territory: String, area: String) {
        self.employeeNumber = employeeNumber
        self.firstName = firstName
        self.lastName = lastName
        self.territory = territory
        self.area = area
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

// Wraps UPC lookup. Keep this thin — SwiftData's indexed @Attribute(.unique)
// on Product.upc is what makes lookups fast at any catalog size.
struct CatalogService {
    let context: ModelContext

    // Looks up a UPC with format-flexibility. Tries the exact value first,
    // then common variants: adding a leading zero (12-digit UPC-A -> 13-digit
    // EAN-13), stripping a leading zero (13-digit -> 12-digit). This handles
    // the fact that scanners report UPC-A barcodes as EAN-13 on some devices
    // and as UPC-A on others, without assuming which format the catalog uses.
    func lookup(upc: String) -> Product? {
        let candidates = upcCandidates(from: upc)
        for candidate in candidates {
            let descriptor = FetchDescriptor<Product>(
                predicate: #Predicate { $0.upc == candidate }
            )
            if let match = try? context.fetch(descriptor).first {
                return match
            }
        }
        return nil
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

// MARK: - Sync service

// Pulls the catalog CSV from a shared source and replaces the local
// Product table atomically. For SharePoint, swap fetchCSV() for a
// Microsoft Graph call using MSAL — see comments at the call site.
//
// CSV format expected (first row is header):
//   upc,name,price,category
//   037000127116,Tide Pods 42ct,19.99,Laundry
//
// Prices parse as Decimal via NSDecimalNumber(string:) to avoid
// floating-point drift.
actor SyncService {
    enum SyncError: Error {
        case badResponse
        case malformedCSV(line: Int, reason: String)
        case emptyCatalog
        case emptyRoster
    }

    struct ParsedProduct {
        let upc: String
        let name: String
        let price: Decimal
        let category: String?
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

            let decimal = NSDecimalNumber(string: priceStr)
            guard decimal != .notANumber else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "price not a number")
            }
            result.append(ParsedProduct(upc: upc, name: name, price: decimal as Decimal, category: category))
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
            context.insert(Product(upc: p.upc, name: p.name, price: p.price, category: p.category, lastUpdated: now))
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
                    reason: "expected 5 columns: employeeNumber, firstName, lastName, territory, area"
                )
            }
            let employeeNumber = cols[0].trimmingCharacters(in: .whitespaces)
            let firstName = cols[1].trimmingCharacters(in: .whitespaces)
            let lastName = cols[2].trimmingCharacters(in: .whitespaces)
            let territory = cols[3].trimmingCharacters(in: .whitespaces)
            let area = cols[4].trimmingCharacters(in: .whitespaces)

            guard !employeeNumber.isEmpty else {
                throw SyncError.malformedCSV(line: idx + 1, reason: "employeeNumber is empty")
            }
            result.append(ParsedAreaManager(
                employeeNumber: employeeNumber,
                firstName: firstName,
                lastName: lastName,
                territory: territory,
                area: area
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
                area: am.area
            ))
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

    // Drive the empty-catalog banner. When the catalog has zero products
    // (fresh install, failed sync, etc.) scanning will always fail — show
    // an explicit warning so the AM knows to sync instead of assuming
    // every product they scan is legitimately missing.
    @Query private var products: [Product]
    @State private var catalogCoordinator = CatalogSyncCoordinator.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if products.isEmpty {
                    emptyCatalogBanner
                } else if isCatalogSyncing {
                    catalogSyncingIndicator
                }
                statusBar
                scanField
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
            .onAppear { inputFocused = true }
            .sheet(isPresented: $showManualOverride) {
                ManualPriceSheet(upc: missingUPC) { override in
                    addManualItem(override)
                }
            }
            .sheet(isPresented: $showSubmitConfirm) {
                SubmitSheet {
                    submit()
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraScannerView(notFoundUPC: cameraNotFoundUPC) { upc in
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
                Button("Submit credit") { showSubmitConfirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.items.isEmpty || store.isOverLimit)
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

        // If we're in edit mode when a scan arrives, the AM has moved on
        // from editing. Exit cleanly so the new item shows in the normal
        // list view, not as an unselected row in the selection list.
        if editMode.isEditing {
            withAnimation {
                editMode = .inactive
                selectedItems.removeAll()
            }
        }

        let catalog = CatalogService(context: context)
        if let product = catalog.lookup(upc: upc) {
            store.add(.init(
                upc: product.upc,
                name: product.name,
                price: product.price,
                manualOverride: false,
                overrideNote: nil,
                scannedAt: .now
            ))
            cameraNotFoundUPC = nil
            return .added
        } else {
            AudioService.shared.playNotFound()
            missingUPC = upc
            if showCamera {
                // Camera mode: flash the UPC in the camera UI so the AM
                // sees the not-found. Don't open the override sheet over
                // the camera — they can close camera and retry.
                cameraNotFoundUPC = upc
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
        // Only submits that are under the limit should reach here (the
        // button is disabled otherwise), but we re-check before writing.
        guard !store.isOverLimit else { return }
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
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Submit credit request?")
                    .font(.title3).fontWeight(.medium)
                Text("This will record the current session to the audit log and clear the scan list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Confirm and submit") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Submit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - History, session detail, settings (stubs)

struct HistoryView: View {
    @Query(sort: \ScanSession.startedAt, order: .reverse) private var sessions: [ScanSession]

    var body: some View {
        NavigationStack {
            List(sessions) { session in
                NavigationLink(value: session.id) {
                    HistoryRow(session: session)
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

    private var itemsSummary: String {
        let lines = session.items.count
        let units = session.items.reduce(0) { $0 + $1.quantity }
        return lines == units
            ? "\(lines) items"
            : "\(lines) items · \(units) units"
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

    init(sessionID: UUID) {
        self.sessionID = sessionID
        _sessions = Query(filter: #Predicate<ScanSession> { $0.id == sessionID })
    }

    var body: some View {
        if let session = sessions.first {
            // TODO: build out the receipt view — header (date, store,
            // AM name), flagged banner if over limit, item rows with
            // manual-override badges, footer with catalog freshness.
            Text("Session detail for \(session.startedAt.formatted())")
        } else {
            Text("Session not found")
        }
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var isSyncing = false
    @State private var lastSyncMessage: String = ""

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
        guard let url = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n/view?usp=share_link") else { return }
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
                Text("Not in catalog: \(lastScannedUPC)")
                    .font(.caption).monospaced()
                    .foregroundStyle(.red)
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
//           let url = URL(string: "https://drive.google.com/file/d/1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n/view?usp=share_link")!
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
