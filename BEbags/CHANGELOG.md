# Changelog

## v1.0.0

* Initial release
* Inventory bag unification
* Bank sync and viewing
* Deposit functionality
* Double-click inspect

## v1.1.0

* Added 4 selectable theme presets (Classic, Diablo, Emerald, Frost)
* Added Destroy and Drop cursor actions
* Improved quick actions menu (removed redundant buttons)
* UI polish and stability improvements

## v1.1.1

* Moved Destroy/Drop buttons to right side
* Improved safety and layout

## v1.1.2

### Improvements

* Bank snapshots now only load for the current character/server
* Destroy and Drop are separated from Deposit for safer use
* Deprecated bank sync/status config toggles removed
* UI layout cleaned up for a more stable top bar

### Notes

* README and screenshots unchanged
* This is a quality-of-life and safety update

## v1.1.3

### Added

* Help button on main UI
* Value highlight documentation

### Improved

* Field manual layout (more readable)
* Safer action button separation

### Fixed

* UI alignment issues

## v1.2.0

### Added

* Sell All system (≥ 1pp) with full stack support
* Sorting system upgraded for better visual experience (Drop down menu with: Bag Order, High→Low, Low→High, Name A→Z, Name Z→A)
* KEEP (Do Not Sell) toggle via Alt + Right Click
* Sell queue system for reliable bulk selling

### Improved

* Sell All now respects current sort order
* UI layout redesigned for clarity and usability
* Sort control moved and simplified (dropdown next to Help)
* Action grouping improved (safe vs dangerous actions)
* Field manual rewritten for clarity and accuracy
* Overall UI alignment and spacing polish

### Changed

* Value highlighting suppressed on KEEP items
* Removing KEEP restores normal glow behavior

### Fixed

* Multiple UI alignment inconsistencies

### Notes

* This release focuses on usability, safety, and polish
* BEbags is currently considered feature-complete for core inventory management until new features are added


## v1.2.1

### Added

* Config files now stored in `e3\config\BEbags`
* Bag space indicator overlay on launcher icon
* Configurable overlay options:

  * Size (Small / Medium / Large)
  * Style (Clean / Bold)
  * Outline (Off / Light / Heavy)
  * Position (center + corners)
  * X/Y offset controls
* Toggle to enable/disable bag space overlay

### Improved

* Switched config + cache saving to `mq.pickle` (no lag, auto directory creation)
* Config window layout significantly cleaned up and reorganized
* Field manual redesigned with collapsible sections and Quick Tips
* Overlay text alignment, readability, and centering improved
* Threshold-based bag space coloring refined and normalized

### Changed

* Config and bank cache paths moved to dedicated BEbags folder
* Default behavior updated to disable bag space overlay (opt-in feature)

### Fixed

* Config folder creation errors and save failures
* Overlay positioning inconsistencies
* Threshold display mismatches in config UI
* Multiple UI alignment edge cases

### Notes

* No migration is performed for old config files
* New config files will be generated automatically on save
* This release focuses on performance, organization, and UI polish
