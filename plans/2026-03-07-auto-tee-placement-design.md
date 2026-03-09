# Auto-Sequenced Tee Placement

## Problem

When using the tee tool in the map editor, every click assigns the first tee name from `course.tees`. The user must manually change each tee name in the inspector. This is tedious for courses with 4-6 tee boxes across 18 holes.

## Design

### Scorecard Tee Ordering

Sort `course.tees` by descending total yardage during scorecard import. `ScorecardImporter.buildCourse()` sums each tee's yardages across all holes and orders the `TeeDefinition` array longest-first. Since `ScorecardTableView` iterates `course.tees` in array order, columns automatically display longest-to-shortest left-to-right.

### Tee Tool Multi-Click Sequencing

When the tee tool is active and the user clicks the map:

1. **Build the sequence** -- for the current hole, collect all tee names from `course.tees`. Sort into two groups:
   - Tees with yardage data for this hole, sorted by descending yards
   - Tees without yardage data, in `course.tees` definition order

2. **Filter already-placed tees** -- check existing pins for this hole and remove tee names that already have a pin. This produces the "remaining tees" list.

3. **Assign on click** -- the next click places a tee pin with the first name from the remaining list.

4. **Auto-complete** -- when no tees remain after a placement, switch `activeTool` back to `.select` and show "All tees placed" in the status bar.

5. **Hint text** -- while the tee tool is active, the status bar shows: `"Click to place [TeeName] tee ([Yards] yds)"` for tees with yardage, or `"Click to place [TeeName] tee"` for those without.

6. **Resume behavior** -- since the sequence is computed from existing pins each time, switching away and back to the tee tool naturally resumes where the user left off.

### Per-Hole Ordering

Each hole sorts tees independently by that hole's yardages. For example, if hole 1 has Black as longest but hole 2 has Gold as longest, the placement order differs per hole.

## Files Changed

- **`ScorecardImporter.swift`** -- sort `course.tees` by descending total yardage after building the course
- **`MapEditorView.swift`** -- add `remainingTeesForCurrentHole()` computed method, modify tee pin placement to use it, auto-switch to select when done, update hint text

## Files Unchanged

- `ScorecardView.swift` / `ScorecardTableView` -- already iterates `course.tees` in array order
- `PinEditorView.swift` -- tee name picker still works for manual overrides
- Data models -- no schema changes
