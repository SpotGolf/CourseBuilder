# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CourseBuilder — a macOS SwiftUI desktop app for creating golf course GPS data files. Part of the SpotGolf project. Produces JSON files with tee, green, and hazard coordinates for each hole.

## Build & Test

Requires xcodegen (`brew install xcodegen`).

```bash
xcodegen generate
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' build
xcodebuild -scheme CourseBuilder -destination 'platform=macOS' test
```

## Architecture

- macOS 14+ (Sonoma), Swift, SwiftUI, no external packages
- MapKit for satellite map display and course search
- CoreImage for satellite imagery color analysis (green/tee detection)
- Vision framework for scorecard image OCR
- GolfCourseAPI.com (free tier) for structured scorecard data

## Key Data Flow

Course search (MapKit) -> Scorecard import (API/scraping/OCR) -> Feature detection (satellite analysis) -> Manual pin editing (map UI) -> JSON export

## Data Model

One JSON file per course. Holes contain: tees (keyed by name), green (front/middle/back), features (bunker/water with front/back). See `plans/2026-03-02-course-data-design.md` for full schema.

## Git

Default branch is `main`.

## Environment

GolfCourseAPI.com key is configured in app Settings (Cmd+,).
