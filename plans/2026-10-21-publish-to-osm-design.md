# Publish to OSM

## Problem

Users fix OSM features in the map editor: they move points, fit outlines to imagery, change types, draw new features, and delete wrong ones. Today those fixes stay in CourseBuilder. They should be sent back to OpenStreetMap so everyone gets them.

## Decisions

| Topic                 | Decision                                                                                                                                                                                                                                                       |
|-----------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| What is sent          | Changed features (type or points), bunkers missing their `golf=bunker` tag, new features, deleted features, fairways converted to multipolygons, and greens added to fairway relations. Centerlines count as features (`golf=hole` ways).                      |
| How changes are found | Compare the course to a saved copy of what OSM had (the "baseline"). No event tracking.                                                                                                                                                                        |
| Button                | "Publish to OSM" in the map editor toolbar, next to "Import OSM". Shown only when there is at least one change.                                                                                                                                                |
| Comment dialog        | Text area pre-filled with two blank lines, then `Edited by <user> using CourseBuilder - <instant>`. `<user>` is the signed-in OSM display name. The instant is ISO 8601 in UTC, to the second (`2026-10-21T21:52:08Z`), taken when the dialog opens. Editable. |
| Sign in               | OAuth 2.0 with PKCE through `ASWebAuthenticationSession`. One client ID, built into the app. Token kept in the Keychain.                                                                                                                                       |
| Server                | Production only. Features are imported from production, so the OSM test server, which has its own database, does not have them.                                                                                                                                |
| Upload                | One changeset per publish. One `osmChange` upload, which OSM applies all or nothing.                                                                                                                                                                           |
| Relations             | Type changes go to the relation. Point changes go to the relation's one outer way. A deleted relation is deleted with its untagged outer ways.                                                                                                                 |
| Multipolygons         | A fairway way with OSM greens fully inside it can be converted to a multipolygon relation. A fairway relation missing a green fully inside it can get that green as an inner member. Both are recorded in the editor and sent with the next publish.           |
| Conflicts             | If someone changed a way in OSM since the baseline, nothing is sent and the dialog lists the conflicting features.                                                                                                                                             |

## Server

| Web and OAuth                   | API                                     |
|---------------------------------|-----------------------------------------|
| `https://www.openstreetmap.org` | `https://api.openstreetmap.org/api/0.6` |

The OAuth app registered by the developer:

- Name: CourseBuilder
- Redirect URI: `coursebuilder://oauth/callback`
- Confidential: no (desktop app, PKCE)
- Scopes: `read_prefs` (show who is signed in), `write_api`

The client ID goes in `OSMServer` in code.

## Flow

```
Feature edits in the map editor
        │
        ▼
OSMChangeDetector: course vs. baseline → changes (create / modify / multipolygon / delete)
        │  changes not empty
        ▼
"Publish to OSM" button
        │
        ▼
OSMAuth: signed in? if not, browser sign-in → token in Keychain. Fetch display name.
        │
        ▼
Comment dialog (list of changes, comment with the user's name)
        │  Publish
        ▼
OSMAPIClient: fetch current ways/nodes for modified, converted, and deleted features (GET /way/{id}/full),
              and relations plus their outer ways (GET /relation/{id})
        │  version differs from baseline → stop, show conflicts
        ▼
OSMChangeBuilder: build osmChange XML
        │
        ▼
OSMAPIClient: create changeset → upload → close changeset (closed even if upload fails)
        │
        ▼
Apply result: set osmID on created features and converted fairways, save new baseline, save course
```

## Baseline

The baseline is what OSM had for each feature the last time the app and OSM agreed.

| Field per feature | Use                                                                                                                                                                       |
|-------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| OSM id            | Key (`w123`, `r456`)                                                                                                                                                      |
| Version           | Conflict check. `nil` when unknown.                                                                                                                                       |
| Type              | Detect type changes                                                                                                                                                       |
| Points (lat/lon)  | Detect point changes. Elevation is ignored.                                                                                                                               |
| Tags              | The element's tags, shown in the inspector. `nil` when unknown.                                                                                                           |
| Members           | Relations only. Each member's type, id, and role, shown in the inspector. The inner way members decide which greens Add Green to Multipolygon offers. `nil` when unknown. |

- The baseline also holds the pending multipolygon conversions (see below), since they are what the course still owes OSM. Baselines saved before this have none.
- Stored per course at `~/Library/Application Support/CourseBuilder/osm-baselines/<course id>.json`. It is kept out of the `courses` folder because `CourseStore` loads every `.json` file there as a course.
- Written after an OSM import and after each publish.
- The Overpass query changes from `out geom;` to `out geom meta;` so imports include each element's version.
- Imports save each element's tags and, for relations, members from the Overpass response.
- The Overpass query also asks for `natural=sand` ways and relations. One with no `golf` tag is imported as a bunker, since some mappers tag a bunker only as sand. Sand outside the course, such as a beach, can come in this way; the user ignores it rather than deleting it, since deleting it deletes it from OSM.
- After a publish, each sent element's entry takes the tags and members that were sent. Nothing extra is read from OSM.
- Baselines saved before tags and members were kept have them as unknown. When a course is opened, the app reads the unknown ones from OSM (`GET /ways.json?ways=<ids>` and `GET /relations.json?relations=<ids>`, up to 100 ids per request, no sign in needed) and saves them to the baseline. Versions are not changed by this, since the conflict check compares to them. If a request fails, the details stay unknown and are read again the next time the course is opened.
- Courses imported before this change have no baseline. The first time such a course is opened, a baseline is made from its current features with unknown versions. Edits made before that point are not detected.

## Finding changes

| Case                                                                              | Change                 |
|-----------------------------------------------------------------------------------|------------------------|
| Feature has no OSM id                                                             | Create                 |
| Feature's OSM id is in the baseline, type or points differ                        | Modify                 |
| Bunker whose baseline tags have no `golf` tag (tags known, type unchanged)        | Modify (adds golf tag) |
| Baseline OSM id has no feature in the course                                      | Delete                 |
| Pending multipolygon whose fairway and at least one green are still in the course | Multipolygon           |

A relation's points are the points of its outer way, so a point change on a relation is a Modify. A deleted relation is a Delete, like a deleted way.

Points are equal when every point is within 0.5 m of the baseline point at the same position. Course files store points to about 1 foot, so exact comparison would report false changes.

Undo needs no special handling. Undoing an edit makes the feature match the baseline again.

## Tags

| Type       | Tags for new features                         |
|------------|-----------------------------------------------|
| fairway    | `golf=fairway`                                |
| green      | `golf=green`                                  |
| tee        | `golf=tee`                                    |
| bunker     | `golf=bunker`, `natural=sand`                 |
| water      | `golf=water_hazard`, `natural=water`          |
| centerline | `golf=hole`, `ref=<hole number>`, `par=<par>` |

Type change on an existing feature: remove the old type's tags from the table above (only those that are present), then add the new type's tags. All other tags are kept.

Bunker missing its `golf` tag: add the bunker tags from the table above that are not present (`golf=bunker`; `natural=sand` is usually there already). All other tags are kept. Only bunkers get this: a way tagged only `natural=water` may be a lake that is not a hazard, so water is left alone.

Every changeset gets `comment` (from the dialog) and `created_by=CourseBuilder <version>`.

## Writing points to a way

OSM ways are lists of nodes. Point changes are written like this:

1. Fetch the way and its nodes (`/way/{id}/full`).
2. For each point in the feature, reuse an existing node of that way within 0.5 m. A reused node is not moved.
3. Points with no close node become new nodes (negative ids).
4. Areas (all types except centerline) are closed: the last node is the first node.
5. Old nodes no longer used by the way are deleted with `if-unused="true"`, only when they have no tags. OSM keeps any node another way still uses.

New features: all points become new nodes, plus a new way with the tags above.

Deleted features: delete the way, then its untagged nodes with `if-unused="true"`.

## Relations

OSM's golf course guidance asks for a multipolygon when a fringe of fairway surrounds a green: the fairway outline is the outer way, the green way is an inner way. The outer way usually has no tags; the relation has them. The green way keeps `golf=green`.

### Editing a relation's points

The app shows a relation fairway as its outer outline. Changing that outline changes the outer way:

1. Fetch the relation (`/relation/{id}`) and find its outer members.
2. If it does not have exactly one outer way, stop and show "Relation r… has N outer ways." Nothing is sent.
3. Fetch the outer way (`/way/{id}/full`) and write the points to it as in "Writing points to a way". Nodes shared with the green stay shared unless they moved.
4. The relation is only sent when its type changed. Its baseline version stays the same otherwise.

Inner ways are not changed. Greens and bunkers that are inner ways are their own features and are edited as normal ways.

### Deleting a relation

1. Fetch the relation (`/relation/{id}`) and each of its outer ways (`/way/{id}/full`).
2. Delete the relation.
3. Delete each outer way that has no tags, then its untagged nodes. An outer way with tags is its own feature and is kept.
4. Inner ways are not deleted. They are their own features.

All deletes use `if-unused="true"`, and the relation comes first in the `<delete>` block so its ways are no longer used by it. OSM keeps any way or node that another element still uses, such as an outer way shared with another relation. An outer way that is also changed in the same upload is not deleted.

### Convert to Multipolygon

| Topic        | Decision                                                                                                                                                                                                                |
|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Offered when | The selected feature is a fairway that is an OSM way (`w…`) or relation (`r…`), and one or more OSM green ways have every point inside it. For a relation, greens the baseline lists as its inner members are left out. |
| Not offered  | Greens that only touch or cross the fairway outline. OSM's guidance is to share nodes there, and an inner ring outside the outer is invalid. Features not yet in OSM.                                                   |
| Where        | A button in the inspector, below the hole controls: "Convert to Multipolygon" for a fairway way, "Add Green to Multipolygon" for a fairway relation.                                                                    |
| Recorded as  | A pending conversion in the baseline: the fairway's OSM id and the inner greens' OSM ids. Shown in the inspector with "Cancel Multipolygon".                                                                            |
| Sent         | With the next publish, in the same changeset as other changes. Listed in the dialog as a "Multipolygon" row.                                                                                                            |
| Dropped      | When the fairway is deleted, or all of its greens are.                                                                                                                                                                  |

The upload:

| Element      | Change                                                                                                                               |
|--------------|--------------------------------------------------------------------------------------------------------------------------------------|
| New relation | Created with `type=multipolygon` plus every tag the fairway way had. Members: the fairway way as `outer`, each green way as `inner`. |
| Fairway way  | Modified to have no tags. Its points change too if the fairway was also reshaped.                                                    |
| Green ways   | Not changed.                                                                                                                         |

For a fairway relation, the upload changes only the relation:

| Element              | Change                                                                                                                                                                       |
|----------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Fairway relation     | Each green that is not a member is added as `inner`. A green that is a member with no role gets `inner`. Members with a role are not changed. Not sent when nothing changes. |
| Outer and green ways | Not changed.                                                                                                                                                                 |

After the upload, the fairway feature's OSM id becomes the new relation's `r…` id. The baseline drops the way's entry, adds the relation's with the tags and members sent, and removes the pending conversion. For a fairway relation, the baseline takes the members sent and the new version, and removes the pending change.

## Comment dialog

```
┌ Publish to OSM ─────────────────────────────────────────┐
│ ┌─────────────────────────────────────────────────────┐ │
│ │ Changed      Bunker  #12 Hole 3 w4512 points       ▲│ │
│ │ Changed      Water   #18 Hole 5 w4520 type, was    ││ │
│ │                                       bunker       ││ │
│ │ Multipolygon Fairway #44 Hole 2 w4540 inner: w4541 ││ │
│ │ New          Tee     #97 Hole 7                    ││ │
│ │ Deleted      Bunker             w4533              ││ │
│ │ Deleted      Fairway            r881               ▼│ │
│ └─────────────────────────────────────────────────────┘ │
│ ┌─────────────────────────────────────────────────────┐ │
│ │ |                                                   │ │
│ │                                                     │ │
│ │ Edited by <user> using CourseBuilder -              │ │
│ │ 2026-10-21T21:52:08Z                                │ │
│ └─────────────────────────────────────────────────────┘ │
│ Signed in to openstreetmap.org as <user>                │
│                                  [Cancel]  [Publish]    │
└─────────────────────────────────────────────────────────┘
```

- The top of the dialog is a scrollable list with one row per change, in this order: Changed, Multipolygon, New, Deleted. Within each group, rows are in hole order.
- Each row shows:

| Column  | Shows                                                                                                                                                 |
|---------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| Action  | Changed, Multipolygon, New, or Deleted                                                                                                                |
| Type    | Feature type. For a deleted feature, the type from the baseline.                                                                                      |
| Feature | Feature id (`#12`). Empty for a deleted feature.                                                                                                      |
| Hole    | The hole that uses the feature. Empty when no hole uses it.                                                                                           |
| OSM id  | `w…` or `r…`. Empty for a new feature.                                                                                                                |
| Detail  | Changed: `points`, `type, was <old type>`, `adds golf=bunker`, or a list of them. Multipolygon: `inner: <green OSM ids>`. Conflict: `changed in OSM`. |

- Conflict rows are shown in red at the top of the list.
- Sign in happens before the dialog opens, so the comment can include the user's name. If sign in is cancelled or fails, the dialog does not open and the error shows in the status area.
- The cursor starts on the first line of the comment.
- Publish shows a spinner and blocks the dialog until done.
- On success: close the dialog, show "Published changeset <id>" in the status area, with a link to the changeset on openstreetmap.org.
- On error or conflict: keep the dialog open and show the message. Nothing is changed in the course or baseline.

## Inspector

The inspector shows the selected feature. Below the feature number and type picker are four sections:

| Section  | Shows                                                                                                                                                                              |
|----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| General  | Vertex count, area, and centroid.                                                                                                                                                  |
| OSM      | Only for features in OSM. The OSM id linked to its page, the version, the tags, and for a relation each member's id (linked) and role. A member with no role shows "no role".      |
| Vertices | Each point's index, latitude, and longitude. Read only and scrollable; text can be selected. Points are edited on the map.                                                         |
| Actions  | Associate or Disassociate with the hole, Revert to OSM, Convert to Multipolygon or Add Green to Multipolygon (or the pending change with Cancel Multipolygon), and Delete Feature. |

- The OSM section reads the baseline entry, so selecting a feature makes no network request.
- When the entry's tags are unknown, the section shows "Tags not read from OSM yet".
- The Vertices section takes the space the other sections leave.

## Settings

| Setting     | Control                                         |
|-------------|-------------------------------------------------|
| OSM account | "Signed in as <user>" with Sign Out, or Sign In |

## New code

| File                               | Holds                                                                                                    |
|------------------------------------|----------------------------------------------------------------------------------------------------------|
| `Services/OSMServer.swift`         | Server URLs and client ID                                                                                |
| `Services/OSMAuth.swift`           | OAuth sign in, Keychain token, sign out                                                                  |
| `Services/OSMAPIClient.swift`      | User details, way and relation fetch, reading tags and members in batches, changeset create/upload/close |
| `Services/OSMBaseline.swift`       | Baseline type and its load/save                                                                          |
| `Services/OSMMultipolygon.swift`   | Pending conversion type, the "green inside fairway" check, and the greens a relation is missing          |
| `Services/OSMChangeDetector.swift` | Course vs. baseline → list of changes                                                                    |
| `Services/OSMChangeBuilder.swift`  | Tags, node matching, osmChange XML, applying the upload result                                           |
| `Views/PublishToOSMSheet.swift`    | Comment dialog                                                                                           |

Changes to existing code:

- `OverpassAPIClient`: `out geom meta;`, read `version` and tags onto parsed features and centerlines, read relation members.
- `MapEditorView`: Publish button, sheet, write the baseline after import, Convert to Multipolygon and Add Green to Multipolygon in the inspector, fill unknown tags and members when a course is opened.
- `FeatureEditorView`: General, OSM, Vertices, and Actions sections; read-only vertex list; OSM details from the baseline.
- `SettingsView`: account row.

## Tests

| Area             | Cases                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
|------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Change detection | No changes; type change; moved point; point within 0.5 m is not a change; new; deleted; relation points sent; relation delete sent; sand bunker gets golf tag, not when it has one, its tags are unknown, or it is water; pending multipolygon; multipolygon dropped without greens                                                                                                                                                                                                                                                                                                       |
| Tags             | Each type; type change keeps other tags; `natural=water` without `golf` tag; `golf=bunker` added to a sand way and relation, other tags kept, no change after publish                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Node matching    | Unchanged points reuse nodes; moved point makes a new node; way is closed; centerline is not                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| osmChange XML    | Create, modify, delete with `if-unused`; versions included; relation delete removes untagged outer ways, keeps tagged ones and inner ways                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Upload result    | New ids set on features; baseline updated with new versions and the tags and members sent; deleted ids removed, including relations                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| API client       | Stubbed `URLProtocol`: changeset closed after a failed upload; 409 reported as a conflict; relation outer way fetched; relation with two outer ways rejected; deleted relation fetches every outer way; tags and members read without sign in; reads split into batches of 100                                                                                                                                                                                                                                                                                                            |
| Multipolygons    | Green inside offered; green crossing the outline and new green not offered; green missing from a relation fairway offered, and not offered when the baseline lists it; missing green added to a relation, empty role fixed, nothing sent when none missing; relation members recorded after upload; unknown tags and members filled without changing versions; relation created with tags and members; fairway tags removed; relation point edit changes only the outer way; fairway gets the relation id; relation keeps its version when only the outer way changed; old baselines load |
| Overpass parsing | Versions read from `out geom meta` responses; relation members read; query asks for `natural=sand`; sand with no `golf` tag parsed as a bunker                                                                                                                                                                                                                                                                                                                                                                                                                                            |

Sign in is checked by hand against openstreetmap.org.

## Not in this version

- Editing relations with more than one outer way.
- Sharing nodes between a fairway and a green that only touch.
- Merging with someone else's changes after a conflict.
- Splitting a changeset that is over the OSM limit of 10,000 changes.
