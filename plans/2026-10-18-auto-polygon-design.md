# Auto Polygon and Fit to Imagery

## Problem

OSM polygons are often poor. Today the user fixes them by dragging points one at a time, or deletes them and draws new ones by hand. Two tools speed this up:

1. **Auto polygon tool** — click inside a bunker, green, tee, fairway, or water area and get a polygon.
2. **Fit to Imagery** — a context menu command on the selected polygon that replaces its outline with one traced from imagery.

## Decisions

| Topic           | Decision                                                                                                                |
|-----------------|-------------------------------------------------------------------------------------------------------------------------|
| Imagery source  | USDA NAIP (public domain), read through the Microsoft Planetary Computer tile API. No API key.                         |
| Apple imagery   | Still shown in the editor. Never analyzed. Apple's terms (Attachment 6, sections 2.2, 2.3, 2.5) forbid data derived from it. |
| NAIP display    | Not shown. It is fetched and analyzed in the background only.                                                           |
| Lidar           | Not used in this version.                                                                                               |
| Fit result      | Replaces the whole outline. The old polygon is only a guide. Point count may change.                                    |
| Detection       | Color grouping (region growing) in plain Swift. No ML model.                                                            |
| Coverage        | Lower 48 US states only. Elsewhere the tools show "No NAIP imagery here."                                               |

## Flow

```
User click (auto tool) or Fit to Imagery (selected polygon)
        │
        ▼
NAIPImageryClient: find newest NAIP year for the area, fetch tiles (color + near-infrared), cache on disk
        │
        ▼
ImagePatch: stitched pixels + pixel ↔ lat/long conversion (Web Mercator)
        │
        ▼
FeatureSegmenter: seed colors → grow region → clean up mask
        │
        ▼
OutlineTracer: trace mask outline → simplify → lat/long polygon
        │
        ▼
Preview on map (dashed outline) → Enter accepts, Esc cancels, [ ] change tolerance
        │
        ▼
Course updated, undo record pushed, elevation worker fills elevations
```

## Imagery: `NAIPImageryClient`

New file `Services/NAIPImageryClient.swift`. Follows the style of `OverpassAPIClient` (async, `URLSession`, testable with injected data loader).

1. **Find imagery.** `POST https://planetarycomputer.microsoft.com/api/stac/v1/search` with collection `naip` and the area's bounding box. Pick the newest year. Read its `gsd` (0.3, 0.6, or 1.0 m).
2. **Register a mosaic** for that year and box: `POST /api/data/v1/mosaic/register`. Keep the returned search ID per course for the session.
3. **Pick zoom from `gsd`.**

   | gsd   | Zoom | Meters per pixel at 40° N |
   |-------|------|---------------------------|
   | 0.3 m | 19   | 0.23                      |
   | 0.6 m | 18   | 0.46                      |
   | 1.0 m | 17   | 0.91                      |

4. **Fetch tiles** (256 px) covering the work area from `/api/data/v1/mosaic/{id}/tiles/WebMercatorQuad/{z}/{x}/{y}?collection=naip&assets=image&format=png`:
   - Color: `asset_bidx=image|1,2,3`
   - Near-infrared: `asset_bidx=image|4`
   - Fetch up to 8 tiles at once.
5. **Disk cache** in `~/Library/Caches/CourseBuilder/naip/{year}/{z}/{x}/{y}-{rgb|nir}.png`. Tiles never change for a given year, so no expiry.
6. **Errors** go to the status bar: no coverage, network failure, bad response.

## Pixels: `ImagePatch`

New file `Services/ImagePatch.swift`.

- Holds width, height, zoom, the global pixel position of its top-left corner, and four `Float` channels (red, green, blue, near-infrared, 0–1).
- Built by decoding tiles with `CGImageSource` and copying them into place.
- `pixel(for: Coordinate) -> CGPoint` and `coordinate(forPixel:) -> Coordinate` using Web Mercator math.
- Coordinates are WGS84 (GPS and Apple Maps). NAIP images are in NAD83 (EPSG:26913), and the tile server places them as if NAD83 were WGS84. That puts NAIP about 1.3 m east and 0.5 m south of true GPS positions at Colorado National Golf Club. `ImagePatch` holds a `datumOffset` and applies it in both conversions, so traced features land at true GPS positions.

### Datum: `NAD83`

New file `Services/NAD83.swift`. Converts WGS84 to NAD83(2011) with the NGS 14-parameter transformation from ITRF2008 (Pearson & Snay, 2013), at today's date. WGS84 matches ITRF2008 to within a few centimeters. The offset changes by millimeters across a course, so `NAIPImageryClient` computes one offset per patch from its center and picks tiles for the box shifted into NAD83.

| Check at Colorado National                       | East    | North   |
|--------------------------------------------------|---------|---------|
| Computed offset (NAD83 − WGS84)                  | +1.35 m | −0.52 m |
| Fit vs saved features, before the correction     | +0.99 m | −0.33 m |
| Fit vs saved features, after the correction      | −0.31 m | +0.24 m |
- `metersPerPixel` at the patch's latitude.

## Detection: `FeatureSegmenter`

New file `Services/FeatureSegmenter.swift`. Pure functions on an `ImagePatch`. No UI or network code.

### Per-pixel values

| Value       | Formula                         | Why                                     |
|-------------|---------------------------------|-----------------------------------------|
| L, a, b     | sRGB → CIELAB                   | Color distance that matches the eye     |
| NDVI        | (NIR − red) / (NIR + red)       | Separates grass, sand, and water        |

### Seed statistics

- **Auto tool:** pixels within 1.5 m of the click.
- **Fit:** pixels inside the old polygon, shrunk by 1 m. If that leaves fewer than 20 pixels, use the whole polygon.
  - Keep only the pixels that pass the type rule, so other ground inside the old outline (for example grass inside a bunker outline) does not set the colors.
  - If none pass, the outline missed the feature. Use the pixels that pass the type rule anywhere in the fit search area.
- Compute the median and the spread (median absolute deviation) of each value. Use a minimum spread so a flat seed does not reject everything.

### Region growing

- Flood fill (4 neighbors) from the seed pixels.
- A pixel joins when its scaled distance from the seed median is at most `tolerance`. Default `tolerance` comes from the feature type.
- Type rules must also pass:

  | Type    | Rule                                | Default tolerance | Max search radius (auto tool) | Fit search margin |
  |---------|-------------------------------------|-------------------|-------------------------------|-------------------|
  | Bunker  | NDVI < 0.15                         | 3.0               | 40 m                          | 5 m               |
  | Water   | NDVI < 0.3 and L < 45               | 3.0               | 300 m                         | 15 m              |
  | Green   | 0.2 < NDVI < 0.42 and L > 42        | 2.0               | 60 m                          | 5 m               |
  | Tee     | NDVI > 0.2 and L > 40               | 2.5               | 40 m                          | 5 m               |
  | Fairway | NDVI > 0.25                         | 2.0               | 400 m                         | 15 m              |
  | Rough   | NDVI > 0.2                          | 3.0               | 400 m                         | 15 m              |

- The rules come from NAIP pixels measured inside each feature type at Colorado National Golf Club (2023, 30 cm):

  | Type    | Median NDVI | Median L |
  |---------|-------------|----------|
  | Bunker  | 0.02        | 71       |
  | Water   | 0.19        | 32       |
  | Green   | 0.32        | 51       |
  | Tee     | 0.39        | 47       |
  | Fairway | 0.44        | 41       |
  | Rough   | 0.46        | 40       |

  Ponds there look green in NAIP, so the water rule allows NDVI up to 0.3. Greens are brighter and less green than fairway and rough.

- **Auto tool** search area: a circle of the max radius around the click.
- **Fit** search area: the old polygon grown by the fit margin.

### Telling grass types apart

Fairway, rough, green, and tee colors are close: rough is only about 1.7 color units from fairway, under the tolerance, so growing from the seed colors takes in the rough. But each pixel is still closer to one group than the other. Measured at Colorado National, a simple two-group comparison of color tells them apart:

| Pair             | Correct |
|------------------|---------|
| Green vs fairway | 98%     |
| Tee vs rough     | 93%     |
| Fairway vs rough | 89%     |
| Tee vs fairway   | 78%     |

Texture (local variation in brightness) added almost nothing, so it is not used.

Two steps use this. Both first average each value over about 0.5 m to remove pixel noise, and both model a group as the mean and variance of L, a, b, and NDVI.

1. **Fit refinement (`FeatureSegmenter.refine`).** Start from the old outline. Compare the colors inside it (shrunk by 1 m) with the band 1–8 m outside it. Keep the pixels in the fit search area that pass the type rule and look more like the inside than the band, clean up, and repeat up to 4 times as the outline settles.
2. **Auto split (`FeatureSegmenter.splitFromSurroundings`).** After growing from a click, split the grown area into two color groups: start one from the seed colors and one from the 30% of pixels least like them, then re-assign 6 times. Keep the seed's group. Skip the split when the groups are not clearly different (separation under 2.0) or the other group is under 15% of the area, so a uniform feature is left alone.

Tolerance still works with `[` and `]`: each step above the type's default makes a pixel 0.5 log-likelihood units more likely to stay in the feature.

| Type          | Fit                 | Auto tool        |
|---------------|---------------------|------------------|
| Fairway, rough | Refinement         | Grow, then split |
| Green, tee    | Refinement          | Grow             |
| Bunker, water | Grow                | Grow             |

Results at Colorado National, as median overlap (IoU) with the saved features (1.0 is a perfect match):

| Type    | Fit before → after | Auto before → after |
|---------|--------------------|---------------------|
| Fairway | 0.61 → 0.87        | 0.56 → 0.84         |
| Green   | 0.89 → 0.92        | 0.90 (unchanged)    |
| Tee     | 0.62 → 0.66        | 0.61 (unchanged)    |
| Bunker  | 1.00 (unchanged)   | 0.98 (unchanged)    |

The saved tees there are rough OSM circles, so tee scores understate how well the traced pads fit. Splitting greens and tees in the auto tool, and refining bunkers, made them worse, so those are not used.

### Mask cleanup

1. Close small gaps (grow, then shrink, by about 0.6 m).
2. Remove thin spurs and specks (shrink, then grow, by about 0.6 m).
3. Fill holes.
4. Keep only the largest connected piece that holds a seed.

### Sanity check (fit only)

If the new area is under 50% or over 200% of the old area, keep the preview but show "Result differs a lot from the original" in the status bar.

## Outline: `OutlineTracer`

New file `Services/OutlineTracer.swift`. Pure functions.

1. Trace the outer edge of the mask along pixel edges, keeping the inside on the right.
2. Reduce points (see "Point count" below).
3. Convert pixels to `Coordinate` values with no elevation. The elevation worker fills elevations after the change, as it does for drawn polygons.
4. Fail if fewer than 3 points remain.

### Point count

Course files are downloaded to the SpotGolf app and the watch, so polygons must not carry extra points. Shape accuracy comes first: complex shapes keep the points they need, and simple shapes end up small.

1. **Error limit (main rule).** First smooth the traced edge to remove pixel noise: take the midpoint of each pixel step, then average each point with its neighbors over about twice the error limit of edge. Then simplify with Douglas–Peucker. Every part of the outline stays within the error limit of the smoothed edge.
2. **Minimum spacing.** Drop points closer to the previous kept point than the minimum spacing. This removes pixel noise and does not cut real curves.
3. **Safety limit.** If the result still has more points than the safety limit, do not change the shape. Show a warning in the status bar, for example `Bunker · 140 pts — more than expected`. The user decides whether to accept it.

| Type    | Error limit | Min spacing | Safety limit |
|---------|-------------|-------------|--------------|
| Bunker  | 0.3 m       | 0.75 m      | 80           |
| Tee     | 0.3 m       | 1 m         | 30           |
| Green   | 0.3 m       | 1 m         | 80           |
| Fairway | 1.0 m       | 3 m         | 150          |
| Rough   | 1.5 m       | 3 m         | 150          |
| Water   | 1.0 m       | 2 m         | 120          |

Expected results (to be checked on real courses):

| Shape                               | Points  |
|-------------------------------------|---------|
| Round bunker, 15 m wide             | ~11     |
| Bunker with 5 curves, ~60 m around  | ~30–40  |
| Round green, 30 m wide              | ~16     |
| Green with several lobes            | ~30–45  |
| Fairway                             | ~40–100 |

For reference, saved OSM data today has median point counts of 31 (bunker), 17 (tee), 27 (green), 55 (fairway), 51 (rough), and 31 (water).

All three rules live in one function, `OutlineTracer.reducePoints(_:type:metersPerPixel:)`, so both tools use the same limits.

## Session state: `AutoPolygonSession`

New file `Services/AutoPolygonSession.swift`. Holds one preview in progress so the view stays thin and the logic is testable.

| Field        | Purpose                                                            |
|--------------|--------------------------------------------------------------------|
| `mode`       | `.create(type)` or `.fit(featureID)`                               |
| `patch`      | The fetched `ImagePatch`                                           |
| `seeds`      | Seed regions added with click or Shift-click                       |
| `exclusions` | Seed regions removed with Option-click                             |
| `tolerance`  | Current tolerance, changed with `[` and `]`                        |
| `mask`       | Current result                                                     |
| `preview`    | Traced polygon shown on the map                                    |

Changing seeds or tolerance re-runs detection on the cached patch, so the preview updates without new network calls. A click outside the current patch fetches a larger patch.

## User interface

### Auto polygon tool

- New `ToolMode.autoPolygon`, label "Auto", shortcut `a`, icon `wand.and.stars`.
- The feature type picker shows for this tool, as it does for the polygon tool.

| Input                    | Action                                                                  |
|--------------------------|-------------------------------------------------------------------------|
| Click                    | Start a preview from this point (replaces any current preview)          |
| Shift-click              | Add the area around this point to the preview                           |
| Option-click             | Remove the area around this point from the preview                      |
| `]` / `[`                | Raise / lower tolerance and update the preview                          |
| Enter                    | Add the polygon to the course and to the current hole, select it        |
| Esc                      | Cancel the preview                                                      |

Modifier keys are read from `NSEvent.modifierFlags` when the tap ends.

The tool stays active after Enter so the user can add the next bunker right away.

### Fit to Imagery

- Context menu on the map, shown when a feature is selected:
  - **Fit to Imagery** (also key `f`)
  - **Delete Feature** (uses the existing delete confirmation)
- Fit fetches imagery, shows the new outline dashed, and the old outline faded.
- Enter replaces the polygon. Esc cancels. `[` and `]` change tolerance.

### Status bar

| State              | Text                                                                                       |
|--------------------|--------------------------------------------------------------------------------------------|
| Loading            | `Loading NAIP imagery…`                                                                    |
| Auto preview       | `Bunker preview · 32 pts | ⇧-click add | ⌥-click remove | [ ] tolerance (N) | Enter to add | Esc to cancel` |
| Fit preview        | `Fit preview · 32 pts | [ ] tolerance (N) | Enter to accept | Esc to cancel`               |
| Over safety limit  | `Bunker · 140 pts — more than expected` (added to the preview text)                        |
| Always in preview  | `Imagery: USDA NAIP {year}` (the credit USDA asks for)                                     |

### Preview drawing

- Dashed outline in the feature type's color, light fill.
- Fit mode also draws the old outline at 40% opacity.

## Undo

Today Cmd+Z only restores deleted features (`deletedFeatureRecords`). Replace that list with one undo stack:

```swift
enum FeatureUndoRecord {
    case deleted(DeletedFeatureRecord)
    case replacedPolygon(featureID: Int, oldPolygon: [Coordinate])
    case added(featureID: Int)
}
```

- Fit accept pushes `.replacedPolygon`.
- Auto accept pushes `.added`. Undoing it deletes the feature and removes it from every hole that uses it.
- Delete pushes `.deleted` (same behavior as today).
- Cmd+Z pops and reverses the last record. Undo while drawing still removes the last drawn vertex first.
- The undo functions live in `PolygonEditorOperations` so they can be tested.

## Known limits

- NAIP's own accuracy standard allows up to ±4 m horizontal error (95%) beyond the datum offset. At Colorado National, fits land within about 0.4 m of features placed on Apple imagery after the datum correction.
- Fairway and rough differ only slightly in color. The two-group comparison handles most fairways, but some edges still have notches where rough and fairway look alike. Use `[` and `]` or Shift/Option-click there.
- Tee boxes are hard to tell from nearby fairway (78% of pixels correct).
- Tree shadows and overhanging trees cut into greens and fairways.
- NAIP can be 1–3 years old.

## Files

| File                                    | Change                                                         |
|-----------------------------------------|----------------------------------------------------------------|
| `Services/NAIPImageryClient.swift`      | New                                                            |
| `Services/NAD83.swift`                  | New                                                            |
| `Services/ImagePatch.swift`             | New                                                            |
| `Services/FeatureSegmenter.swift`       | New                                                            |
| `Services/OutlineTracer.swift`          | New                                                            |
| `Services/AutoPolygonSession.swift`     | New                                                            |
| `Services/PolygonEditorOperations.swift`| Undo record type and undo/redo functions                       |
| `Views/PinEditorView.swift`             | `ToolMode.autoPolygon`                                         |
| `Views/MapEditorView.swift`             | Tool handling, context menu, preview drawing, keys, undo stack |

No data model changes.

## Tests

| Test file                            | Covers                                                                                         |
|--------------------------------------|------------------------------------------------------------------------------------------------|
| `NAIPImageryClientTests.swift`       | Newest-year pick, zoom from gsd, tile URLs, tile range for a box (canned JSON, fake loader)    |
| `ImagePatchTests.swift`              | Pixel ↔ coordinate round trip, meters per pixel                                                |
| `NAD83Tests.swift`                   | Offset at Colorado National, patch pixels shift by the offset, round trip with the offset      |
| `FeatureSegmenterTests.swift`        | Synthetic images: sand disk in grass, water in grass, fairway strip; area within 5% of truth    |
| `OutlineTracerTests.swift`           | Square and L-shaped masks trace correctly; simplify keeps corners and drops collinear points; error limit holds; minimum spacing holds; a 5-lobe bunker keeps its lobes; safety limit flags and does not change the shape |
| `AutoPolygonSessionTests.swift`      | Add and remove seeds, tolerance change re-runs, fit sanity warning, auto fairway splits from rough, fit moves an offset fairway outline, fit tolerance keeps more or fewer pixels |
| `PolygonEditorOperationsTests.swift` | Undo for replaced polygon and added feature                                                     |

Plus one manual check on Colorado National Golf Club (2023 NAIP, 30 cm).
