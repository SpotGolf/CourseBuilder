# CourseBuilder

A macOS desktop app for creating golf course GPS data files. Part of the [SpotGolf](https://spot.golf) project.

CourseBuilder produces JSON files containing tee, green, and hazard coordinates for each hole on a golf course. These files are used by the SpotGolf mobile app for on-course GPS distances.

## Features

- **Course Search** — Find golf courses using MapKit search
- **Scorecard Import** — Pull scorecard data from GolfCourseAPI.com, web scraping, or image OCR
- **Satellite Map Editor** — Place and adjust pins for tees, greens, bunkers, and water hazards on a satellite map
- **Distance Verification** — Compare measured tee-to-green distances against scorecard yardages
- **JSON Export** — Export course data as a single JSON file per course

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Building

```bash
# Generate the Xcode project
xcodegen generate

# Build
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build

# Run tests
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test
```

Or open `CourseBuilder.xcodeproj` in Xcode after running `xcodegen generate`.

## Running

1. Build and run from Xcode, or download a pre-built release (see below)
2. Open Settings (Cmd+,) and enter your [GolfCourseAPI.com](https://golfcourseapi.com) API key
3. Create a new course by searching for a golf course or entering details manually
4. Use the scorecard view to import hole data
5. Open the map editor to place GPS pins on each hole
6. Export the finished course as JSON

## Downloads

Pre-built releases are available on the [Releases](https://github.com/SpotGolf/CourseBuilder/releases) page.

## License

Copyright SpotGolf. All rights reserved.
