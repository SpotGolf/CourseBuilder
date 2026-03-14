# FIRs and GIRs — Polygon-First Data Model Redesign

## Overview

Replace the pin-based data model with a polygon-first model so the SpotGolf mobile app can determine Fairways in Regulation (FIR) and Greens in Regulation (GIR) from GPS position. Every spatial element — fairway, green, tee box, bunker, water hazard, rough — becomes a polygon. This is a clean-break rewrite of the data model, JSON format, and map editor.

## Data Model

### Feature

The universal spatial primitive. Every polygon on the course is a Feature.

- `id: Int` — auto-incremented per course
- `type: FeatureType` — `fairway`, `green`, `tee`, `bunker`, `water`, `rough`
- `polygon: [[Double]]` — ordered array of `[lat, lon]` vertices forming a closed polygon

Features live in a flat array at the course level. Holes reference them by ID, allowing features to be shared across holes (e.g., a pond between two holes).

### Hole

Scorecard data, feature references, and a playing path.

- `number: Int` — 1-based within subcourse
- `par: Int`
- `maleHandicap: Int`
- `femaleHandicap: Int`
- `yardages: [String: Int]` — keyed by tee name
- `features: [Int]` — array of Feature IDs
- `tees: [String: Int]` — maps tee name to Feature ID (e.g., `{"Blue": 5, "White": 7}`). Auto-assigned during OSM import by matching tee-to-green distance against yardages, editable in inspector.
- `centerline: [[Double]]` — polyline of `[lat, lon]` waypoints from tee to pin

### Course Structure

```
Course
  id: UUID
  name: String
  clubName: String
  location: Location
    address, city, state, country
    coordinates: [lat, lon]
  tees: [TeeDefinition]          // name + color, no ID (name is unique)
  features: [Feature]            // flat list, all holes reference by ID
  subCourses: [SubCourse]
    id: UUID
    name: String
    holes: [Hole]
    tees: [String: SubCourseTee] // ratings, slope, totals per tee
```

## JSON Format

Clean break — no backward compatibility, no version number.

```json
{
  "id": "uuid",
  "name": "Pine Valley Golf Club",
  "clubName": "Pine Valley",
  "location": {
    "address": "1 Pine Valley Dr",
    "city": "Pine Valley",
    "state": "NJ",
    "country": "US",
    "coordinates": [39.7879, -74.9580]
  },
  "tees": [
    { "name": "Black", "color": "#000000" },
    { "name": "Gold", "color": "#FFD700" }
  ],
  "features": [
    { "id": 1, "type": "tee", "polygon": [[39.788, -74.958], [39.787, -74.957]] },
    { "id": 2, "type": "fairway", "polygon": [[39.787, -74.957], [39.786, -74.956]] },
    { "id": 3, "type": "green", "polygon": [[39.786, -74.956], [39.785, -74.955]] },
    { "id": 4, "type": "bunker", "polygon": [[39.786, -74.955], [39.785, -74.954]] }
  ],
  "subCourses": [
    {
      "id": "uuid",
      "name": "Front",
      "tees": {
        "Black": {
          "male": { "rating": 74.5, "slope": 155, "totalYards": 3600, "parTotal": 36 }
        }
      },
      "holes": [
        {
          "number": 1,
          "par": 4,
          "maleHandicap": 7,
          "femaleHandicap": 5,
          "yardages": { "Black": 427, "Gold": 398 },
          "features": [1, 2, 3, 4],
          "tees": { "Black": 1, "Gold": 5 },
          "centerline": [[39.788, -74.958], [39.786, -74.956]]
        }
      ]
    }
  ]
}
```

## OSM Import Pipeline

After course creation via GolfCourseAPI (metadata, pars, handicaps, yardages, ratings/slope), polygon geometry is imported from OpenStreetMap:

1. **Determine bounding box** — start with the clubhouse coordinate from GolfCourseAPI. Query Overpass API for the `leisure=golf_course` boundary polygon at that location. If found, compute its bounding box and pad it by 20-30% to catch features that extend beyond an incomplete boundary. If no course boundary exists, fall back to a generous radius (~1km) from the clubhouse. Better to fetch extra features than miss course features.

2. **Map OSM tags to feature types:**
   - `golf=fairway` → `fairway`
   - `golf=green` → `green`
   - `golf=tee` → `tee`
   - `golf=bunker` → `bunker`
   - `golf=water_hazard` / `golf=lateral_water_hazard` → `water`
   - `golf=rough` → `rough`

3. **Assign feature IDs** — auto-increment as features are created.

4. **Associate features to holes:**
   - If OSM has `golf=hole` centerlines: use them as the primary association method. Fairways and greens that the centerline passes through get assigned to that hole. Bunkers, water, and rough are assigned by proximity to the centerline.
   - If no centerlines in OSM: fall back to spatial heuristics — cluster tees, fairways, and greens by proximity and infer hole groupings.

5. **Centerlines:**
   - If OSM provided `golf=hole` ways: import directly, skip generation.
   - If not: generate from tee centroid → fairway centroids → green centroid.

6. **User review** — open the map editor with imported features for correction.

## Map Editor

The map editor shifts from pin placement to polygon drawing and editing.

### Tools

- **Select** — click to select a feature polygon. Shows vertices as draggable handles.
- **Draw Polygon** — click to place vertices, double-click or close the shape to finish. Assign a feature type after drawing.
- **Draw Centerline** — click to place waypoints along the playing path from tee to green.
- **Edit Vertices** — drag vertices to reshape, click an edge midpoint to insert a vertex, right-click a vertex to delete it.

### Sidebar

- Hole list — selecting a hole highlights its associated features and centerline on the map.
- Feature list for the selected hole — shows type icons with feature IDs. Click to select on map. Drag to reorder. Button to disassociate a feature from the hole.
- Unassociated features section — features imported from OSM not yet assigned to a hole. Drag onto a hole to associate.

### Inspector

- Selected feature's type (changeable via dropdown), vertex count, computed area.
- For centerlines: list of waypoints with coordinates.

### OSM Import Button

Triggers the import pipeline, populates the map with polygons, opens review mode.

## Derived Properties

Computed from geometry, not stored in JSON.

### From any polygon
- **Centroid** — geometric center
- **Area** — square footage/yards

### From green polygon + centerline direction
- **Front** — nearest point on green polygon to previous centerline waypoint (approach direction)
- **Back** — farthest point from approach direction
- **Middle** — centroid

### From fairway polygon + centerline
- **Landing zone** — centroid of fairway segment where centerline passes through
- **Dogleg detection** — significant direction changes in centerline within the fairway

### From tee polygon
- **Tee position** — centroid, used for distance calculations

### FIR/GIR (mobile app)
- **FIR** — player's ball position after tee shot is inside a fairway polygon associated with that hole
- **GIR** — player's ball position is inside the green polygon in regulation (strokes ≤ par - 2)
