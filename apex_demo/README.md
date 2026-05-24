# KMLeon Demo (APEX 26.1 / APEXLang)

A small APEX 26.1 app (APEXLang format) to exercise and demo KMLeon. Lives in the
repo under `apex_demo/`. Built on top of a **real frontend-exported APEXLang app**
(so the format/version matches APEX 26.1 exactly), then customized for KMLeon.

## Pages (toolkit)
- **1 Jobs (dashboard)** — one page, top to bottom:
  - a **Cards** KPI strip (total / completed / failed / pending+running) top-left and
    a **fixed Map** region (`geojson` layer, all geometry types, auto-zoom) top-right
    at the same height (region `columnSpan` 8 / 4, `startNewRow: false`);
  - an IR over `KML_JOBS` (status badge) full width below — clicking a row's link sets
    `P1_JOB_ID` and reloads focused on that job;
  - an **Assets** IR below, filtered to the selected job (else latest COMPLETED).
  The KPI strip also shows the latest *created / completed / failed / cleanup*
  timestamps (from `KML_CONFIG` metrics).
  Buttons: *New job* + *Process PENDING* are always shown; *Re-run*, *Cancel* and
  *Download* appear **only when a job is selected** (`serverSideCondition` →
  `itemIsNotNull P1_JOB_ID`). Actions run via Dynamic Actions → `PCK_KML_*`.
- **3 New job** — modern form (floating labels, format dropdown) + *Create from
  GeoJSON & run* / *Create from SELECT & run*.
- **5 Logs** — IR over `KML_LOG`.
- **7 Settings** — edit the cleanup job (`CLEANUP_*` in `KML_CONFIG`): enabled,
  interval, retention, statuses. *Save and apply schedule* writes via
  `PCK_KML_CONFIG_DML` + `PCK_KML_MAINTENANCE.apply_schedule`; *Run cleanup now*
  calls `PCK_KML_MAINTENANCE.run_cleanup(p_force => true)`. Plus an IR over all config.
- **9 Download** — streams `result_kmz`/`result_kml` as a file (before-header process).
- `demo_data.sql` — seeds & runs a few jobs via `PCK_KML_JOB_API`.

Actions are wired as **Dynamic Actions** running server-side PL/SQL (no page
branches); the download uses a before-header streaming process. The map layer omits
point-only styling so it renders points, lines and polygons from one geojson source.

## Key format facts (learned from the reference export)
- The **app id lives in `deployments/default.json`** (`app.id`), *not* in
  `application.apx`. There is **no** `workspace` block — the workspace comes from
  the logged-in session / connection. (Our id: **1100**. APEX reserves app IDs
  **3000–8999** and **40000–49999** — pick outside those, and avoid collisions.)
- Content regions on a `@/standard` page use **`slot: body`** (not `contentBody`).
- `.apex/apexlang.json` `mmdVersion` must match the instance (`26.1.0+3102`).

## Import (App Builder or SQLcl)
- **SQLcl** (connect as the schema that owns the KMLeon objects):
  ```bash
  apex validate -input C:\Users\Tobias\Documents\DEV\kmleon_apex_demo
  apex import   -input C:\Users\Tobias\Documents\DEV\kmleon_apex_demo
  ```
- **App Builder**: zip the app folder and import the zip (App Builder ▸ Import).

Then seed data and open the app:
```bash
@C:\Users\Tobias\Documents\DEV\kmleon_apex_demo\demo_data.sql
```

## Still to add (next iteration, against live `apex validate`)
*New job* (form + create/run process), *Process PENDING* button, BLOB download —
using the Dynamic-Action / process syntax now visible in the reference export.
