# Changelog

All notable changes to KMLeon are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). The release number lives in three
places that must agree: [`VERSION`](VERSION), `PCK_KML_ENGINE.gc_version` and the
toolkit app's *Version* attribute (`apex_toolkit/application.apx`). `install.sql`
and `update.sql` stamp it into `KML_CONFIG` (`KMLEON_VERSION`), `GET …/kmleon/v1/version`
reports it, and `tests/smoke_test_version.sql` fails when the stamp is stale.

## [Unreleased]

## [1.1.0] – 2026-11-01

In-place update: run `sql/update.sql` as the KMLeon schema, re-import
`apex_toolkit/` (same application id), re-run `sql/ords/010_rest_api.sql`.
No table changes; all new settings are seeded with behaviour-preserving defaults.

### Fixed
- **Engine ran only with the Oracle JVM.** `SDO_UTIL.TO_KMLGEOMETRY` is Java-based
  and raised `ORA-29538` on databases without OJVM (Oracle Database Free container
  images, minimal installs), so every job failed there. KML geometry is now written
  by the new pure-PL/SQL package `PCK_KML_GEOM`.
- `geometry_geojson` holding a GeoJSON *Feature* was skipped silently
  (`SDO_UTIL.FROM_GEOJSON` accepts bare geometries only); Feature and
  FeatureCollection are now unwrapped.
- `<ExtendedData>` with more than 32 KB of properties disappeared silently
  (varchar2 overflow caught by the best-effort handler); it is built as a CLOB now.
- `apex_toolkit/setup.sql` hung in SQLcl/SQL*Plus (no `set define off` while the
  installed package body contains `&session`).
- REST: `GET jobs/{id}` and `GET jobs/{id}/result` answered a non-numeric id with
  HTTP 555 instead of 400/404.
- Toolkit: Status badges on the Jobs dashboard and the Async playground were
  empty (IR HTML expressions substitute `#COL#`, not `&COL.`).
- Toolkit: every map had a single *Points* layer, so saved lines and polygons were
  never drawn; each map now stacks points / lines / polygons layers.
- Toolkit: the dashboard map never left 0°/0° and showed the last COMPLETED job
  (whose assets are usually already cleaned up); it now zooms to the extent of the
  newest job that still has assets.
- Toolkit docs pointed external apps to a page-100 deep link that fails with a
  session-state-protection violation; the documented target is page 200.
- Login page carried the "TestApp" title of the reference export; Query helper help
  text named the wrong default bind mode.

### Added
- `PCK_KML_GEOM`: pure PL/SQL `SDO_GEOMETRY` → KML (points, lines, polygons with
  holes, multi-geometries, collections, 2D/3D), transforms non-WGS84 SRIDs to
  lon/lat, densifies arcs / compound elements / optimized rectangles, drops LRS
  measures, accepts GeoJSON geometry / Feature / FeatureCollection.
- `<StyleMap>` highlight styles: setting `STYLE_HIGHLIGHT_SCALE` (e.g. `1.3`) adds a
  scaled highlight variant and a StyleMap per shared style (hover effect in Google
  Earth). Off by default.
- Notifications: setting `NOTIFY_SENDER` = `NONE` (default) | `APEX_MAIL` | `CUSTOM`.
  `APEX_MAIL` queues through APEX (`NOTIFY_FROM`, `NOTIFY_APEX_WORKSPACE` for
  scheduler/REST runs) without a compile-time APEX dependency.
- Versioning: `PCK_KML_ENGINE.gc_version` / `version`, `KML_CONFIG.KMLEON_VERSION` +
  `METRIC_LAST_INSTALL_AT` stamped by the install scripts, `GET version` REST endpoint,
  toolkit app version attribute.
- REST: `DELETE jobs/{id}` (409 while PENDING/RUNNING), `GET version`;
  `sql/ords/020_rest_protect.sql` protects the module with an ORDS privilege and an
  OAuth2 client-credentials client (re-runnable, prints the credentials).
- `PCK_KML_JOB_API.delete_job`.
- Toolkit: `IST_ADMIN` is real now – anonymous users are never admins; if the
  workspace group `KMLEON_ADMIN` exists, membership is required (upgrade-safe: without
  the group every authenticated user keeps admin access).
- Tests: `tests/run_all.sql` (pass/fail summary, CI exit code), `tests/rest_smoke.sh`
  (curl/jq, optional OAuth2), new scripts for geometry, large ExtendedData, StyleMap,
  notifications and the release stamp; optional-component tests skip cleanly.
- `install.sql` / `update.sql` recompile dependants (e.g. `PCK_KMLEON_TOOLS`) and
  print the installed version.

### Changed
- `PCK_KML_ENGINE.geometry_to_kml` no longer strips `<extrude>/<tessellate>/<altitudeMode>`
  (the serializer never emits them).
- REST responses with free text (`editor_url`, `access_key`) are built with
  `JSON_OBJECT_T` instead of string concatenation.
- Requirements: Oracle JVM is **not** needed any more; Spatial/Locator still is.

## [1.0.0] – 2026-10 (baseline, commit `a1f7c45`)

Initial public state: job-based KML/KMZ engine (ASSETS / QUERY / GeoJSON sources),
shared styles, folder hierarchies, KMZ via `APEX_ZIP`, scheduler dispatcher,
config/metrics store, cleanup job, notification hooks, ORDS module `kmleon.v1`,
APEX 26.1 toolkit app (APEXLang). Not versioned explicitly; `update.sql` from 1.1.0
onwards stamps the release.
