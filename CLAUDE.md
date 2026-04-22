# AM Credit Tracker

iOS app for Jacent Strategic Merchandising Area Managers to track scanned products and the running credit total against a $149.99 limit. Built with SwiftUI + SwiftData.

## Architecture overview

Single-file Swift project (`AMCreditTrackerApp.swift`, ~3000 lines, brace-balanced). Major sections, in order:

1. **App entry** — `AMCreditTrackerApp` (launches four parallel CSV syncs)
2. **Sync coordinators** — `RosterSyncCoordinator`, `CatalogSyncCoordinator`, `StoreSyncCoordinator`, `TerritoryManagerSyncCoordinator` (each `@Observable @MainActor`)
3. **SwiftData models** — `Product`, `AreaManager`, `Store`, `TerritoryManager`, `ScanSession`, `ScannedItem`, plus `*Sync` audit records for each
4. **Session store** — `ScanSessionStore` (in-memory observable; persists to SwiftData on submit)
5. **Catalog/Store services** — `CatalogService.lookup(upc:store:)`, `StoreService.distinctStoreNames(in:)`, `storeNumbers(for:in:)`
6. **Sync service** — `SyncService` parses Drive-hosted CSVs, atomic full-replace of each table
7. **Audio service** — synthesized PCM tones via AVAudioPlayer (NOT system sounds — those proved unreliable)
8. **Views** — `LaunchCoordinator`, `LoadingRosterView`, `AMPickerView`, `WelcomeView`, `RootTabView`, `ScanView`, `CameraScannerView`, `SubmitSheet`, `MailComposerView`, `HistoryView`, `SessionDetailView`, `SettingsView`

## Reference data sources (Google Drive, "Anyone with link can view")

| File | Schema | Drive ID |
|------|--------|----------|
| `area_managers.csv` | `employeeNumber, firstName, lastName, territory, area, email` (6th optional) | `1rOFqR8IDo4lEJmT39tHtw7JsLggOauxf` |
| `catalog.csv` | `upc, name, price, commodity, store, retailPrice, rank` (12-digit UPC-A; preserve leading zeros; cols 4–7 optional; source header uses "commodity" but the in-app field is still `category`) | `1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n` |
| `stores.csv` | `store, storeNumber, area, shortName` (3rd and 4th optional for backward compat) | `1WtggB4_n1G2avUV4q0Di4VRjG2ZdrEh3` |
| `territory_managers.csv` | `territory, email` | `1eJ7rQLkO9uCwATuPfPCxvSX-jIRnggss` |

`SyncService.normalizeSourceURL` accepts any Drive URL format (share link or direct download) and rewrites to the `uc?export=download&id=...` form.

## Key behavioral decisions

- **Hard limit:** `ScanSessionStore.hardLimit = 149.99`. Triggers over-limit branch in submit flow.
- **Catalog scoping:** `Product.upc` is NOT unique. The composite (upc, store) is the logical primary key, enforced at sync time by full-replace. The same UPC can carry different prices at Target vs. Walmart.
- **Store scoping:** Stores partition by `area` (the AM's specific slice), not by `territory` (the broader region). Case-sensitive exact-match — "Seattle-North" ≠ "Seattle North" ≠ "seattle-north".
- **Store picker filter:** Pickers in `ScanView` are filtered to the signed-in AM's `area`. Empty area = fail-open (show all). When AM switches identity, `validateStoreSelectionForCurrentAM()` clears stale store selections.
- **UPC format flexibility:** `CatalogService.lookup` tries 12-digit, 13-digit-with-leading-zero, and 13-without — handles scanner inconsistencies.
- **Over-limit submit flow:** Submit button changes to "Request approval" (orange) at >$149.99. Tap → `SubmitSheet` with TM email card → "Open email draft" → `MFMailComposeViewController` opens Mail.app pre-filled. Session persists as `.overLimit` only after mail is sent.
- **Audio:** Synthesized 1800Hz confirm chirp (80ms), 380Hz buzzer (350ms). Audio session is `.playback`, primed at app launch.
- **Camera fallback:** `CameraScannerView` (VisionKit `DataScannerViewController`). Closes 0.4s after success, stays open with red error on not-found, distinguishes "Not in catalog" from "Not in this store — available at X".

## Schema migration policy (DEV ONLY)

Container init currently uses `fatalError("ModelContainer failed: \(error)")`. Any change to a `@Model` class crashes existing installs. **During development, the workaround is to delete + reinstall the app.** Before production, replace with a `VersionedSchema` migration plan.

## Coding conventions

- **Comments:** Liberal explanatory comments on non-obvious logic, especially around sync, audio, mail composer wrappers, and store-scoping edge cases. Match the existing tone — explain *why*, not *what*.
- **Edits:** Prefer surgical `str_replace` edits over full-file rewrites. Re-read the file region before editing — it's long and easy to make wrong assumptions.
- **Brace balance:** After any non-trivial edit, verify braces balance. Use the helper command `/balance-check` (see `.claude/commands/`) or run the inline Python script in `scripts/balance.py`.
- **Imports at the top:** `SwiftUI, SwiftData, AudioToolbox, AVFoundation, BackgroundTasks, VisionKit, Vision, MessageUI`. Add new imports here, not inline.
- **No new dependencies without asking:** No SPM packages, no CocoaPods. The point of single-file is no third-party surface area.
- **Error display:** Red errors auto-dismiss after 4s in the scan screen via `scanErrorBanner(message:)`.

## Build & test workflow

- **Build:** Open `~/jacent/AMCreditTracker/AMCreditTracker.xcodeproj` in Xcode → Cmd+R for simulator/device run.
- **Schema-change rebuild:** Delete the app from device/simulator first, then Cmd+R.
- **TestFlight:** Bump build number in General tab → Product → Archive → Distribute App → App Store Connect → Upload.
- **No unit tests yet.** When we add them, target the pure logic in `CatalogService`, `StoreService`, `SyncService.parse*`, and `ScanSessionStore` total/limit math.

## Common gotchas

- `MFMailComposeResult` is Equatable, but `Result<MFMailComposeResult, Error>` is NOT (because `any Error` isn't Equatable). State that needs `.onChange(of:)` should be the bare `MFMailComposeResult?`.
- `@AppStorage` only supports `String`, not `String?`. Use empty string for "not yet set."
- `EditButton` in toolbar didn't fire reliably in our setup; we use a manual `editMode` toggle instead.
- Stepper inside a List row intercepts tap-to-select in edit mode — hide the stepper when `editMode.isEditing`.
- Don't add `Done` button in keyboard toolbar — it overlapped the Submit button at small sizes.
- `dismiss-keyboard-on-outside-tap` was blocking swipe-to-delete handles. We use `scrollDismissesKeyboard(.immediately)` only.

## Outstanding work

- [ ] Info.plist: `NSCameraUsageDescription` (required for App Store / TestFlight)
- [ ] Info.plist: `BGAppRefreshTaskSchedulerPermittedIdentifiers` if we add background sync
- [ ] Replace `fatalError` with `VersionedSchema` migration before any external user has prod data
- [ ] HistoryView filter chips (All / Submitted / Over limit)
- [ ] "Signed-in AM removed from roster" edge case
- [ ] Central upload of submitted sessions (SharePoint list / Power Automate)
- [ ] Android port — same Drive sources, same data contract
