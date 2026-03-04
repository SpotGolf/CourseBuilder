# CourseData Design

## Overview

A macOS SwiftUI desktop app for creating and editing golf course GPS data. Produces JSON files that SpotGolf consumes. The tool combines automated data sourcing (scorecard APIs, web scraping, satellite imagery analysis) with a manual map editor for precise pin placement.

## Pipeline

```
Search for course (MKLocalSearch, .golf POI filter)
  -> Fetch scorecard (GolfCourseAPI.com -> web scraping fallback -> image OCR fallback)
  -> Capture satellite imagery (MKMapSnapshotter)
  -> Detect features via CoreImage HSB color analysis
  -> Present satellite map with detected pins
  -> User adjusts/adds/removes/classifies pins
  -> Export as JSON
```

## Data Model

### Course JSON (output format)

```json
{
  "id": "A5F3B2C1-1234-4567-89AB-CDEF01234567",
  "name": "The Broadlands Golf Course",
  "clubName": "The Broadlands Golf Club",
  "golfCourseAPIId": 19198,
  "location": {
    "address": "4380 W 144th Ave",
    "city": "Broomfield",
    "state": "CO",
    "country": "US",
    "coordinate": { "latitude": 39.9397, "longitude": -105.0267 }
  },
  "tees": [
    {
      "name": "Black", "color": "#000000",
      "male": {
        "courseRating": 73.5, "slopeRating": 137,
        "frontCourseRating": 37.6, "frontSlopeRating": 134,
        "backCourseRating": 38.1, "backSlopeRating": 129,
        "totalYards": 7289, "parTotal": 72
      }
    },
    {
      "name": "Red", "color": "#FF0000",
      "female": {
        "courseRating": 69.1, "slopeRating": 121,
        "frontCourseRating": 34.2, "frontSlopeRating": 118,
        "backCourseRating": 34.9, "backSlopeRating": 124,
        "totalYards": 5200, "parTotal": 72
      }
    }
  ],
  "holes": [
    {
      "number": 1,
      "par": 4,
      "maleHandicap": 13,
      "femaleHandicap": 11,
      "yardages": { "Black": 401, "Gold": 378, "Blue": 355, "Red": 298 },
      "tees": {
        "Black": { "latitude": 39.9401, "longitude": -105.0271 },
        "Gold": { "latitude": 39.9400, "longitude": -105.0270 },
        "Blue": { "latitude": 39.9399, "longitude": -105.0269 },
        "Red": { "latitude": 39.9398, "longitude": -105.0268 }
      },
      "green": {
        "front": { "latitude": 39.9386, "longitude": -105.0246 },
        "middle": { "latitude": 39.9385, "longitude": -105.0245 },
        "back": { "latitude": 39.9384, "longitude": -105.0244 }
      },
      "features": [
        {
          "type": "bunker",
          "front": { "latitude": 39.9387, "longitude": -105.0249 },
          "back": { "latitude": 39.9388, "longitude": -105.0248 }
        },
        {
          "type": "water",
          "front": { "latitude": 39.9394, "longitude": -105.0261 },
          "back": { "latitude": 39.9392, "longitude": -105.0259 }
        }
      ]
    }
  ]
}
```

### Key data model decisions

- One JSON file per course, named by UUID
- `id` is a random UUID v4, `golfCourseAPIId` stores the external API identifier
- `clubName` is the facility/club name; `name` is the specific course name
- `location` includes `address` and `country` in addition to city/state/coordinate
- Tee rating/slope data is grouped into `TeeInformation` structs under `male`/`female` on each tee definition, including front/back nine splits (`frontCourseRating`, `frontSlopeRating`, `backCourseRating`, `backSlopeRating`), `totalYards`, and `parTotal`
- `tees` on each hole is an object keyed by tee name — keys match the course-level tee definitions and `yardages` keys
- `green` is a top-level hole property with `front`, `middle`, `back` coordinates
- `features` only contains hazards (bunkers, water) — each with `front` and `back` coordinates relative to line of play (front = closer to tee, back = far side)
- Holes have separate `maleHandicap` and `femaleHandicap`
- Tee boxes are a single coordinate per tee set
- All coordinates are WGS84 lat/lon

## UI Workflow

### 1. Course List (main window)

- List of courses with name and completion status
- "New Course" button starts the creation workflow
- Click any course to re-open for editing

### 2. Scorecard Import

- Search for course by name (MKLocalSearch with `.golf` POI filter)
- Auto-fetch scorecard from GolfCourseAPI.com (free, 300 req/day, ~30k courses)
- Fallback: scrape from GolfLink or GolfPass (HTML tables, server-side rendered)
- Fallback: load scorecard image, run Vision OCR, parse into hole data
- Fallback: manual entry
- Editable table view showing all holes with par, yardage per tee, handicap

### 3. Map Editor (main workspace)

- Full satellite MapKit view centered on the course
- Left sidebar: hole list (1-18), click to navigate to that hole's area
- Pins displayed per hole: tee boxes (colored by tee set), green (front/middle/back, visually connected), hazard features
- "Auto-detect" button runs CoreImage analysis on the visible region to suggest feature locations
- Real-time distance readout between selected tee and green center vs. scorecard yardage for validation
- Export button saves the JSON file

### Pin interactions

- **Click a pin** — opens editor popover with type picker (tee/green/bunker/water), sub-fields (which tee set, front/middle/back coordinates), editable location fields, delete button
- **Double-click the map** — drops a new untyped pin, immediately opens the editor to classify it
- **Drag a pin** — repositions it, updates the relevant coordinate field

## Auto-Detection

1. MKMapSnapshotter captures the visible map region as NSImage
2. CoreImage HSB filtering isolates dark green manicured turf (greens) and lighter rectangular patches (tee boxes)
3. Detected regions are converted back to map coordinates via the snapshotter's coordinate mapping
4. Candidate pins placed with a "suggested" visual style
5. User confirms, adjusts, or deletes

## Scorecard Data Sources

| Source | Format | Coverage | Priority |
|--------|--------|----------|----------|
| GolfCourseAPI.com | REST JSON | ~30k courses | Primary |
| GolfLink.com | HTML table (`.scorecard-table-container table`) | Large US | Fallback 1 |
| GolfPass.com | HTML table | 30k+ international | Fallback 2 |
| Greenskeeper.org | HTML table (plain `<table>`) | Western US | Fallback 3 |
| Scorecard image | Vision OCR | Any | Manual fallback |

## Technical Stack

- macOS 14+ (Sonoma) for modern SwiftUI MapKit APIs
- Swift, no external packages — all Apple frameworks
- `MapKit` — map display, MKLocalSearch, MKMapSnapshotter
- `Vision` — VNRecognizeTextRequest for scorecard OCR
- `CoreImage` — HSB color filtering for feature detection
- `CoreLocation` — coordinate math, distance calculations
- `URLSession` — API calls and web scraping

## Services

- `CourseSearchService` — wraps MKLocalSearch with `.golf` POI filter
- `ScorecardImporter` — orchestrates API -> scraping -> OCR fallback chain
- `GolfCourseAPIClient` — HTTP client for golfcourseapi.com
- `ScorecardScraper` — HTML parsing for GolfLink/GolfPass
- `ScorecardOCR` — VNRecognizeTextRequest pipeline for scorecard images
- `FeatureDetector` — MKMapSnapshotter + CoreImage HSB filtering
- `CourseStore` — reads/writes course JSON files

## File Structure

```
CourseData/
├── CourseData.xcodeproj
├── CourseData/
│   ├── App/
│   │   └── CourseDataApp.swift
│   ├── Models/
│   │   ├── Course.swift
│   │   ├── Hole.swift
│   │   └── Feature.swift
│   ├── Views/
│   │   ├── CourseListView.swift
│   │   ├── ScorecardImportView.swift
│   │   └── MapEditorView.swift
│   ├── Services/
│   │   ├── CourseSearchService.swift
│   │   ├── ScorecardImporter.swift
│   │   ├── GolfCourseAPIClient.swift
│   │   ├── ScorecardScraper.swift
│   │   ├── ScorecardOCR.swift
│   │   ├── FeatureDetector.swift
│   │   └── CourseStore.swift
│   └── Resources/
└── CourseDataTests/
```
