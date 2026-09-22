# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CourseBuilder — a macOS SwiftUI desktop app for creating golf course GPS data files. Part of the SpotGolf project. Produces JSON files with tee, green, and hazard coordinates for each hole.

## Build & Test

Requires xcodegen (`brew install xcodegen`).

**Always** disable Xcode's sandboxes on every `xcodebuild` and `swift` call: build, test, run, simulator, archive, or anything else.

```bash
xcodegen generate
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES ENABLE_USER_SCRIPT_SANDBOXING=NO build
```

**Never** run the app tests with `xcodebuild test`. Inside Agent Safehouse the test app hangs for 300 seconds and the run fails with "The test runner hung before establishing connection." Run them with the Xcode MCP tools instead:

1. `mcp__xcode__XcodeListWindows` to get the tab ID of `CourseBuilder.xcodeproj`.
2. `mcp__xcode__RunAllTests` or `mcp__xcode__RunSomeTests` with that tab ID.

The project must be open in Xcode. If the `mcp__xcode__*` tools are missing, register the server with `claude mcp add --transport stdio xcode -- xcrun mcpbridge` and restart the session.

To build the CourseDataSwift library, which is included in this project

```bash
swift build --disable-sandbox
swift test --disable-sandbox
```

## Architecture

- macOS 14+ (Sonoma), Swift, SwiftUI, no external packages
- **No app sandboxing.** `com.apple.security.app-sandbox` must remain `false`. Data is stored in `~/Library/Application Support/CourseBuilder/` and sandboxing causes data loss across rebuilds.
- MapKit for satellite map display and course search
- CoreImage for satellite imagery color analysis (green/tee detection)
- Vision framework for scorecard image OCR
- GolfCourseAPI.com (free tier) for structured scorecard data

## Key Data Flow

Course search (MapKit) -> Scorecard import (API/scraping/OCR) -> Feature detection (satellite analysis) -> Manual pin editing (map UI) -> JSON export

## Data Model

One JSON file per course. The Swift types live in the `CourseDataSwift` package (`../CourseDataSwift/Sources`). That code is the source of truth.

| Type      | Holds                                                                                                                                            |
|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| Course    | Name, club name, location, tee list (name and color), features, sub-courses                                                                      |
| Feature   | ID, type (`fairway`, `green`, `tee`, `bunker`, `water`, `rough`), and a polygon (list of points)                                                 |
| SubCourse | A group of holes (e.g. "Front", "Back") with rating, slope, yards, and par for each tee                                                          |
| Hole      | Number, par, handicaps, yardage for each tee, the IDs of its features, its tee boxes (tee name -> feature ID), and a centerline (list of points) |
| Point     | `[latitude, longitude, elevation]`                                                                                                               |

- Elevation is in meters above sea level. It comes from USGS and is optional: `[latitude, longitude]` is also valid.
- Features are stored once on the course. Holes point to them by ID.
- The front, middle, and back of a feature are not stored. They are worked out from the polygon and the hole's centerline.

## Git

Default branch is `main`. **NEVER commit directly to `main`.** Always create a feature branch before starting any implementation work. This branch will always be merged back `main` unless the developer specifically states otherwise. 

## Skills

Project skills live in `.claude/skills/`. Place new skills there, not in `~/.claude/skills/`.

## Environment

GolfCourseAPI.com key is configured in app Settings (Cmd+,).
