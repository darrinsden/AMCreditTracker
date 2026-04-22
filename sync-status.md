---
description: Verify the four Google Drive CSV URLs are still set correctly in AMCreditTrackerApp.swift
---

Find each `private let sourceURL = URL(string: "...")!` declaration in `AMCreditTracker/AMCreditTrackerApp.swift` and report:

1. The four expected URLs (one per coordinator):
   - **RosterSyncCoordinator** → `1rOFqR8IDo4lEJmT39tHtw7JsLggOauxf` (area_managers.csv)
   - **CatalogSyncCoordinator** → `1izR-bDANhkOBlOyvgB9k4gCHOUSn6x5n` (catalog.csv)
   - **StoreSyncCoordinator** → `1WtggB4_n1G2avUV4q0Di4VRjG2ZdrEh3` (stores.csv)
   - **TerritoryManagerSyncCoordinator** → `1eJ7rQLkO9uCwATuPfPCxvSX-jIRnggss` (territory_managers.csv)

2. Whether each URL is the bare `/file/d/<ID>` form (no trailing `/view?usp=...` cruft).

3. Whether any placeholder strings remain (search for `REPLACE_WITH`).

Use `grep -n "drive.google.com/file/d/" AMCreditTracker/AMCreditTrackerApp.swift` to find them quickly.
