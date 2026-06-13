# KMLeon Toolkit (APEX 26.1 / APEXLang)

An APEX 26.1 application that doubles as **development toolkit** for KMLeon: build
jobs from GeoJSON or a SELECT, watch them run sync / async, preview geometries on a
map, inspect logs, manage cleanup settings, download results, and **integrate
KMLeon into your own PL/SQL** via the Query helper. Lives in the repo under
`apex_toolkit/`. Built on top of a **real frontend-exported APEXLang app** so the
format/version matches APEX 26.1 exactly.

## Pages
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
- **11 Editor** — a map-based geometry + style workbench. **Draw** geometries freehand
  (point / line / polygon via a custom MapLibre layer using the map's `getMapObject()`),
  **style** them with **live preview** (line/fill color, width, opacity), then **Save
  asset** to a job (pick a DRAFT job or any job that still has assets — the editor creates
  a draft on first save). The job's existing assets are listed in an **Interactive Grid**;
  **click a row** and its geometry loads back onto the map and its style into the form —
  edit and **Save asset** to update it in place (via `PCK_KML_JOB_ASSETS_DML.upd`).
  **New / clear** starts a fresh feature. **Build
  snippet & KML** copies a ready-made `PCK_KML_JOB_API.add_asset(...)` call *and* the raw
  KML `<Style>` fragment for hardcoding into your own app. **Run job** + **Download**
  render and fetch the KML/KMZ. (Styling/outputs use `PCK_KMLEON_TOOLS.style_outputs`;
  stored colors load back into the pickers via `kml_to_rgb`/`kml_alpha`. Note: *Run job*
  finalises the DRAFT and, per the global `DELETE_ASSETS_AFTER_SUCCESS` setting, may clear
  its assets afterwards — turn that off on the Settings page to keep editing.)
- **10 Query helper** — paste a candidate `QUERY` SELECT (+ optional binds JSON), click
  *Analyze*: the page parses it with `DBMS_SQL`, describes every column and matches each
  alias to its **KMLeon role** (geometry/name/folder/style/… or `ExtendedData`), then
  emits two **ready-to-paste PL/SQL snippets** &mdash; a one-line
  `l_query CLOB := q'<delim>…<delim>';` and a full `declare ... PCK_KML_JOB_API.create_job_from_query ... run_async` block (safe q-quoting that picks a delimiter the query does not contain). A second button **Create test job and run async** runs the same query end-to-end so you can verify it produces a valid KML/KMZ before integrating.
- **8 Async playground** — build a deliberately slow `QUERY` job (`points × seconds`,
  via the `pck_kmleon_tools.row_sleep` per-row sleep helper; set **seconds = 0** to
  run as fast as possible) and run it via a **Run mode** toggle to compare: *Async*
  (`submit_job(p_async => true)`, returns instantly, status report **auto-refreshes
  every 2 s** `PENDING → RUNNING → COMPLETED`) vs *Sync* (`run_now`, blocks the request
  until done). A **Scheduler jobs running now** table (`USER_SCHEDULER_JOBS` +
  `USER_SCHEDULER_RUNNING_JOBS`, auto-refreshing) shows whether two async jobs run in
  parallel (`RUNNING`) or one is throttled (`SCHEDULED`).
- **5 Logs** — IR over `KML_LOG`.
- **7 Settings** — edit the cleanup job (`CLEANUP_*` in `KML_CONFIG`): enabled,
  interval, retention, statuses. *Save and apply schedule* writes via
  `PCK_KML_CONFIG_DML` + `PCK_KML_MAINTENANCE.apply_schedule`; *Run cleanup now*
  calls `PCK_KML_MAINTENANCE.run_cleanup(p_force => true)`. Plus an IR over all config.
- **9 Download** — streams `result_kmz`/`result_kml` as a file (before-header process).

Actions are wired as **Dynamic Actions** running server-side PL/SQL (no page
branches); the download uses a before-header streaming process. The map layer omits
point-only styling so it renders points, lines and polygons from one geojson source.

## Helper package: `PCK_KMLEON_TOOLS`

Functions the toolkit pages call live in the package
[`../sql/packages/pck_kmleon_tools.sql`](../sql/packages/pck_kmleon_tools.sql)
(alongside the core KMLeon packages; installed by `setup.sql`, owned by the
KMLeon schema):

| Member | Purpose |
|---|---|
| `row_sleep(p_seconds)` | per-row sleep used by the Async playground SELECT |
| `qstring(p_text)` | wrap a CLOB in a safe `q'<delim>...<delim>'` literal |
| `qstring_inline(p_text, p_inline_names)` | like `qstring`, but split around caller-resolved placeholders so the output reads `q'~prefix~' || :NAME || q'~suffix~'` |
| `role_of(p_alias)` | map a SELECT column alias to its KMLeon role |
| `type_name(p_type, p_len)` | friendly name for a `DBMS_SQL` column-type code |
| `engine_schema` | the schema names resolve to here (the engine schema; package is `AUTHID DEFINER`) |
| `query_helper(p_query, p_binds, …, p_inline_binds, …)` | parse + describe + produce snippets (Query helper page); `p_inline_binds` lists caller-resolved placeholders |
| `style_outputs(p_geojson, …style…)` | build an `add_asset(...)` snippet + raw KML `<Style>` XML from a geometry + style choices (Editor page) |
| `kml_to_rgb(p_kml)` / `kml_alpha(p_kml)` | convert a stored KML `aabbggrr` color back to `#RRGGBB` / its 0–255 alpha (Editor loads asset colors into the pickers) |

Cross-schema notes: the Query helper validates the SELECT **as the engine schema**
(`PCK_KMLEON_TOOLS` is `AUTHID DEFINER`), so a successful parse means the engine can
run it. If a table lives in another schema, qualify it (`OTHER_SCHEMA.TABLE`), create a
synonym in the engine schema, or use a DB link &mdash; the parser will tell you when
it cannot resolve a name.

Two kinds of binds in a `QUERY` source — **auto-classified**:
- **Engine binds** — whatever names you declare in `source_binds` JSON
  (e.g. `{"region":"DE"}`); the engine binds them at job time.
- **Inline binds** (caller-resolved, **default**) — every other `:NAME` the helper
  finds in the query (e.g. `:P200_ID` for an APEX page item), resolved by the
  *calling* session at submit time.

The *Inline binds* field on the page is just an explicit override; leave it empty for
auto-detection. The *Status* line reports both sets and the chosen mode. (Validation
does not need to strip a `WHERE :Px = ...` clause &mdash; `DBMS_SQL.parse` checks
syntax + names, not bind values.)

**Bind mode** controls *where* inline binds are baked in:

| Mode | `source_query` | `source_binds` |
|---|---|---|
| **`QUERY`** (default) | `q'~...~' || :P200_ID || q'~...~'` (literal) | `q'~{"region":"DE"}~'` (unchanged) |
| **`JSON`** | `q'~... where id = :P200_ID ...~'` (intact) | `'{"region":"DE","P200_ID":"' || :P200_ID || '"}'` |

`QUERY` is simpler (value visible on the job row); `JSON` keeps the stored SQL clean and
benefits from Oracle's plan cache because the engine binds the value at run time.
Inline values are wrapped as JSON strings; Oracle converts to NUMBER on bind when the
target column type requires it.

## Key format facts (learned from the reference export)
- The **app id lives in `deployments/default.json`** (`app.id`), *not* in
  `application.apx`. There is **no** `workspace` block — the workspace comes from
  the logged-in session / connection. (App id: **1100**. APEX reserves app IDs
  **3000–8999** and **40000–49999** — pick outside those, and avoid collisions.)
- Content regions on a `@/standard` page use **`slot: body`** (not `contentBody`).
- `.apex/apexlang.json` `mmdVersion` must match the instance (`26.1.0+3102`).

## Install (App Builder or SQLcl)
- **SQLcl** (run from the repo root, connected as the schema that owns the KMLeon objects):
  ```bash
  apex validate -input apex_toolkit
  apex import   -input apex_toolkit
  ```
- **App Builder**: zip the app folder and import the zip (App Builder ▸ Import).

Then install the helper package and a few sample jobs:
```sql
@apex_toolkit/setup.sql
```
This creates `PCK_KMLEON_TOOLS` (the page helpers) and seeds a few sample jobs via
`PCK_KML_JOB_API` so the reports have data immediately. Requires the **CREATE JOB**
privilege for the Async playground (`run_async`) and the cleanup scheduler.
