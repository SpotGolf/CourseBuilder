# CourseBuilder

<p align="center">
<img width="512" height="512" alt="icon_512x512" src="https://github.com/user-attachments/assets/41be3ccd-c198-4b1d-9255-ead5818a0ae0" />
</p>

A macOS desktop app for creating golf course GPS data files. Part of the [SpotGolf](https://spot.golf) project.

CourseBuilder produces JSON files containing tee, green, and hazard coordinates for each hole on a golf course. These files are used by the SpotGolf mobile app for on-course GPS distances.

## Features

- **Course Search** — Find a course with MapKit search, or enter it by hand with reverse geocoding
- **Scorecard Import** — Pull scorecard data from GolfCourseAPI.com, web scraping, or image OCR
- **Update Course Info** — Reload names, tees, ratings, slopes, par, handicaps, and yardages from GolfCourseAPI.com while keeping map data
- **Combo Tees** — Build combo tees from 2 tees, guessed from the tee name and matching yardages
- **OpenStreetMap Import** — Import OSM polygons and centerlines around the course, and remove hole groups that are not part of it
- **Map Editor** — Draw and edit tee, green, fairway, bunker, and water polygons and hole centerlines on Esri World Imagery or USDA NAIP imagery
- **Auto Polygon Tool** — Trace a feature from a click on the imagery
- **Fit to Imagery** — Replace a polygon's outline with one traced from the imagery
- **Elevations** — Fill in point elevations from USGS in the background, with sea level for courses outside the US
- **Publish to OpenStreetMap** — Send new, changed, and deleted features back to OSM, including Cut Out Green and Fix Course Outline repairs
- **JSON Export** — Check the course for problems, then save it as JSON in the CourseData folder layout

If you would like to help with the project, open a PR. We'll review your PR and add you to the project if it looks good.

## Requirements

| To                | Need                                                                                                           |
|-------------------|----------------------------------------------------------------------------------------------------------------|
| Run               | macOS 27 or later                                                                                              |
| Build             | Xcode 27 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.38.0 or later (`brew install xcodegen`) |
| Import scorecards | A [GolfCourseAPI.com](https://golfcourseapi.com) API key (free tier)                                           |
| Publish to OSM    | An [OpenStreetMap](https://www.openstreetmap.org) account                                                      |

## Building

```bash
# Generate the Xcode project
xcodegen generate

# Build
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build
```

Or open `CourseBuilder.xcodeproj` in Xcode after running `xcodegen generate`. Run the tests from Xcode with Cmd+U.

## Running

1. Build and run from Xcode, or download a pre-built release (see below)
2. Open Settings (Cmd+,), enter your GolfCourseAPI.com API key, and sign in to OpenStreetMap if you plan to publish
3. Create a new course by searching for a golf course or entering details manually
4. Use the scorecard view to import hole data
5. Open the map editor to import OSM data and draw or fix features and centerlines for each hole
6. Publish your map changes to OpenStreetMap (optional)
7. Export the finished course as JSON

## Downloads

Pre-built releases are available on the [Releases](https://github.com/SpotGolf/CourseBuilder/releases) page.
