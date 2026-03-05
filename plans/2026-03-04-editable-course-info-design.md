# Editable Course Info Design

**Date:** 2026-03-04

## Overview

Make all course-level information editable inline within the ScorecardView header area. This includes course name, club name, location fields, tee definitions, and sub-course names.

## Changes to ScorecardView

### Header Section

Replace the static `Text(course.name)` with a vertical stack of `TextField`s:

- **Course Name** — `TextField` bound to `$course.name`
- **Club Name** — `TextField` bound to `$course.clubName`
- **Address** — `TextField` bound to `$course.location.address`
- **City / State / Country** — `TextField`s in an `HStack`, bound to the respective `$course.location` fields

Use `.textFieldStyle(.roundedBorder)` consistent with the existing scorecard table fields. Labels via placeholder text or small caption labels above each field.

### Tee Definitions Section

Below the location fields, show tee definitions as editable rows:

- Each row: `TextField` for tee name + `ColorPicker` for tee color
- A "+" button to add a new tee definition
- A "-" button on each row to remove it

When a tee is added or removed, the scorecard table columns update accordingly (they already derive from `course.tees`).

### Sub-Course Names

In `ScorecardTableView`, replace the static `Text(subCourse.name)` section headers with `TextField($subCourse.name)` so users can rename sub-courses inline.

## Scope of Changes

- `ScorecardView.swift` — Rewrite header to use TextFields; add tee editing section; make sub-course names editable
- No model changes needed — all fields are already `var`
- No new files
