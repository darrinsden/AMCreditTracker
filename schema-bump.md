---
description: Reminder checklist when a SwiftData @Model class changes
---

A `@Model` class was just added, removed, or had a field added/removed/renamed. Walk through this checklist:

1. **Verify the model is registered in the Schema:**
   - Open `AMCreditTrackerApp.swift`, find `let schema = Schema([ ... ])` near the top
   - Confirm the new/modified model appears in the list

2. **If it's a new model, also add the corresponding `*Sync` audit record** (e.g. `Store` → `StoreSync`)

3. **Update the parser if a CSV-backed model:**
   - `parseAreaManagers` / `parseCatalog` / `parseStores` / `parseTerritoryManagers`
   - Update the `Parsed*` struct
   - Update the corresponding `applyAtomicReplace*` method

4. **Update related services:**
   - `CatalogService.lookup(...)` if Product changed
   - `StoreService.distinctStoreNames(in:)` / `storeNumbers(for:in:)` if Store changed
   - Computed properties on ScanView (e.g. `currentAMArea`) if AreaManager changed

5. **Reminder to user:** "Schema changed — you'll need to **delete the app from the device/simulator** before rebuilding, otherwise SwiftData will throw `ModelContainer failed`."

6. **Run `/balance-check` to verify the file still compiles structurally.**
