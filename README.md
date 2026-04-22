# AM Credit Tracker

iOS app for Jacent Strategic Merchandising Area Managers to scan products and track running credit totals against the $149.99 limit. Over-limit sessions trigger an emailed approval request to the Territory Manager.

Built with SwiftUI + SwiftData, no third-party dependencies.

## Setup

### Prerequisites
- macOS with Xcode 16 or later
- An Apple Developer account (for device deployment / TestFlight)
- iOS 17+ target (SwiftData requirement)

### Open the project
```bash
open AMCreditTracker.xcodeproj
```

Then in Xcode:
- Select your Apple ID under **Signing & Capabilities → Team**
- Pick a destination (simulator or your iPhone)
- **Cmd+R** to build and run

### Reference data

The app pulls four CSVs from Google Drive at launch. Make sure each is set to "Anyone with the link can view." See [CLAUDE.md](./CLAUDE.md) for the schemas and the current Drive IDs.

| File | Purpose |
|------|---------|
| `area_managers.csv` | Roster of AMs with territory + area assignments |
| `catalog.csv` | Products with prices, scoped per retailer chain |
| `stores.csv` | Store locations (chain + number + area) |
| `territory_managers.csv` | TM emails for over-limit approvals |

The four URLs are hardcoded in the `*SyncCoordinator` classes near the top of `AMCreditTrackerApp.swift`. To swap a URL, edit the `private let sourceURL = URL(string: "...")!` line in the relevant coordinator.

## Schema changes during development

If you add or remove a field on a `@Model` class, **delete the app from the simulator/device before rebuilding.** Otherwise SwiftData throws `ModelContainer failed: ...`.

This shortcut works fine in dev. Before shipping to real users with real audit log data, replace the `fatalError` in the container init with a `VersionedSchema` migration plan.

## Architecture

Single-file Swift project (`AMCreditTrackerApp.swift`). Major pieces:

- **Sync coordinators** — four `@Observable @MainActor` singletons that pull each CSV in parallel at launch
- **SwiftData models** — Product, AreaManager, Store, TerritoryManager, ScanSession, ScannedItem, plus `*Sync` audit records
- **Catalog/Store services** — wrap UPC lookup and store-picker filtering
- **ScanView** — main scanning screen; hand scanner via focused TextField, camera fallback via VisionKit
- **SubmitSheet** — branches between under-limit (direct submit) and over-limit (TM approval email)
- **MailComposerView** — UIViewControllerRepresentable wrapper around MFMailComposeViewController

See [CLAUDE.md](./CLAUDE.md) for the full architecture notes, behavioral decisions, and gotchas.

## Working with Claude Code

This project ships with a `.claude/` directory that configures Claude Code with project-level settings, slash commands, and instructions. Useful commands:

- `/balance-check` — verify Swift braces balance after an edit
- `/sync-status` — verify the four Drive URLs are current and not placeholders
- `/schema-bump` — checklist after changing a `@Model` class

The full project context lives in [CLAUDE.md](./CLAUDE.md), which Claude Code reads at session start.

## Deployment

### TestFlight
1. Bump the build number in **Xcode → Project → General → Build**
2. Set destination to **Any iOS Device (arm64)**
3. **Product → Archive**
4. In the Organizer: **Distribute App → App Store Connect → Upload**
5. Wait ~10 minutes for processing in App Store Connect
6. Add testers under the **TestFlight** tab

### Required Info.plist keys (TODO before TestFlight)
- `NSCameraUsageDescription` — explain why we use the camera (barcode scanning)

## Known issues

- Audit log is local-only — survives app restarts and phone restarts, but not app deletion. Add iCloud sync or a server upload before any production rollout.
- No automated tests yet. When added, target the parser/catalog/limit math.

## License / ownership

Internal Jacent Strategic Merchandising tool. Not for redistribution.
