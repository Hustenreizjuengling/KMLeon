# KMLeon data model

Three tables. The application owns the data; the engine is generic. **All writes
go through the DML packages** — never INSERT/UPDATE/DELETE the tables directly.

| Table | DML package |
|---|---|
| `KML_JOBS` | `PCK_KML_JOBS_DML` |
| `KML_JOB_ASSETS` | `PCK_KML_JOB_ASSETS_DML` |
| `KML_LOG` | `PCK_KML_LOG` |

Every table ends with the audit columns `created_at`, `created_by`, `updated_at`,
`updated_by`, auto-stamped by the DML package when passed NULL.

## `KML_JOBS`

One row per export request and its result.

| Column | Type | Notes |
|---|---|---|
| `job_id` | NUMBER (identity, PK) | |
| `document_name` | VARCHAR2(400) | KML `<Document><name>`. Required. |
| `description` | VARCHAR2(4000) | KML `<Document><description>`. |
| `output_format` | VARCHAR2(3) | `KML` or `KMZ` (default `KMZ`). |
| `status` | VARCHAR2(20) | `DRAFT`→`PENDING`→`RUNNING`→`COMPLETED`/`FAILED`/`CANCELLED`. |
| `priority` | NUMBER | Lower is processed first (default 100). |
| `output_filename` | VARCHAR2(260) | Suggested download name. |
| `source_type` | VARCHAR2(10) | `ASSETS` (render `KML_JOB_ASSETS`) or `QUERY` (run a SELECT). |
| `source_mode` | VARCHAR2(12) | `QUERY` jobs: `STREAM` (direct to KML, default) or `MATERIALIZE` (write assets first). |
| `source_query` | CLOB | `QUERY` jobs: the SELECT run at job time. |
| `source_binds` | CLOB | `QUERY` jobs: JSON object of bind values, e.g. `{"region":"DE"}`. |
| `user_tab` | VARCHAR2(128) | Source table of the creating user (for later notification). |
| `user_id` | VARCHAR2(128) | Creating user's id within `user_tab`. |
| `result_kml` | CLOB | Populated when `output_format = KML`. |
| `result_kmz` | BLOB | Populated when `output_format = KMZ`. |
| `result_size_bytes` | NUMBER | Size of the produced artifact. |
| `asset_count` | NUMBER | Features rendered. |
| `error_message` | VARCHAR2(4000) | Set when `status = FAILED`. |
| `started_at` / `finished_at` | TIMESTAMP | Execution window. |
| audit (4 cols) | — | See above. |

## `KML_JOB_ASSETS`

One row per map feature. `job_id` → `KML_JOBS` with `ON DELETE CASCADE`.

| Column | Type | Notes |
|---|---|---|
| `asset_id` | NUMBER (identity, PK) | |
| `job_id` | NUMBER (FK) | |
| `folder_name` | VARCHAR2(1000) | Single-level `<Folder>`; `NULL` = under `<Document>`. |
| `display_order` | NUMBER | Render order within a folder (default 0). |
| `name` | VARCHAR2(400) | `<Placemark><name>`. |
| `description` | CLOB | `<description>`; HTML allowed, CDATA-wrapped. |
| `extended_data` | CLOB | JSON object `{"k":"v",...}` → `<ExtendedData>` (balloon). |
| `visibility` | VARCHAR2(1) | `Y`/`N` (default `Y`). |
| `geometry_sdo` | SDO_GEOMETRY | Native geometry (preferred). |
| `geometry_geojson` | CLOB | GeoJSON geometry/feature (used if `geometry_sdo` is NULL). |
| `altitude_mode` | VARCHAR2(20) | `clampToGround`/`relativeToGround`/`absolute`. |
| `extrude` / `tessellate` | VARCHAR2(1) | `Y`/`N`. |
| `icon_href` / `icon_scale` | VARCHAR2 / NUMBER | Point icon. |
| `label_color` / `label_scale` | VARCHAR2(8) / NUMBER | `aabbggrr`. |
| `line_color` / `line_width` | VARCHAR2(8) / NUMBER | `aabbggrr`. |
| `poly_color` | VARCHAR2(8) | `aabbggrr` fill color. |
| `poly_fill` / `poly_outline` | VARCHAR2(1) | `Y`/`N`. |
| audit (4 cols) | — | See above. |

Exactly one of `geometry_sdo` / `geometry_geojson` must be supplied
(enforced in `PCK_KML_JOB_ASSETS_DML.ins`).

## `KML_LOG`

Central log, written only by `PCK_KML_LOG` (autonomous transaction).

| Column | Type | Notes |
|---|---|---|
| `log_id` | NUMBER (identity, PK) | |
| `log_level` | VARCHAR2(10) | `ERROR`/`WARN`/`INFO`/`DEBUG`. |
| `package_name` / `routine_name` | VARCHAR2(128) | Origin. |
| `job_id` | NUMBER | Optional correlation to `KML_JOBS`. |
| `message` | CLOB | |
| audit (4 cols) | — | |

Threshold is `INFO` by default; change with `PCK_KML_LOG.set_threshold('DEBUG')`.

## Query source (`source_type = 'QUERY'`)

Instead of filling `KML_JOB_ASSETS`, a job may carry a `SELECT` in `source_query`.
At run time `PCK_KML_ENGINE` parses it with `DBMS_SQL`, inspects the column
**aliases** (`DESCRIBE_COLUMNS3`), and streams each row directly into the KML —
nothing is written to `KML_JOB_ASSETS`. This keeps the (potentially slow) data
fetch inside the asynchronous job.

Recognized aliases (case-insensitive):

| Alias | Maps to |
|---|---|
| `GEOMETRY` / `GEOMETRY_SDO` | geometry, as `SDO_GEOMETRY` |
| `GEOMETRY_GEOJSON` | geometry, as GeoJSON text |
| `GEOMETRY_KML` | geometry, already KML (passthrough) |
| `NAME`, `DESCRIPTION`, `FOLDER_NAME`, `VISIBILITY` | placemark basics |
| `ICON_HREF`, `ICON_SCALE`, `LABEL_COLOR`, `LABEL_SCALE` | style |
| `LINE_COLOR`, `LINE_WIDTH`, `POLY_COLOR`, `POLY_FILL`, `POLY_OUTLINE` | style |
| `ALTITUDE_MODE`, `EXTRUDE`, `TESSELLATE` | placement (3D viewers; `Y`/`N` for the flags) |
| `EXTENDED_DATA` | JSON object → `<ExtendedData>` |
| *(any other column)* | one `<ExtendedData>` property, name = alias |
| `DISPLAY_ORDER` | ignored (ordering comes from the query's `ORDER BY`) |

By default the query **streams** to KML. With `source_mode = 'MATERIALIZE'` the
engine first inserts each row into `KML_JOB_ASSETS` (via `PCK_KML_JOB_ASSETS_DML`,
unknown aliases → `extended_data` JSON) and then renders from those assets —
choose this when you want the rendered features persisted/inspectable.
`GEOMETRY_KML` passthrough is not storable, so it is skipped under MATERIALIZE.

Notes:

- Provide exactly one geometry alias per row.
- `ORDER BY` the folder column if you want contiguous `<Folder>` grouping.
- Parameters must be **binds** referenced as `:name`, supplied via `source_binds`
  JSON; bind values are passed as strings.
- Supported column data types: VARCHAR2/CHAR, NUMBER, DATE, TIMESTAMP,
  TIMESTAMP WITH TIME ZONE, CLOB, and `SDO_GEOMETRY`. CAST anything else in the SELECT.
- **Security:** the query runs as the KMLeon (definer) schema in the dispatcher;
  only trusted callers should enqueue `QUERY` jobs.

## GeoJSON ingestion (external / REST)

`PCK_KML_JOB_ASSETS_DML.add_features_geojson(p_job_id, p_feature_collection)`
(also surfaced as `PCK_KML_JOB_API.add_features_geojson`) bulk-inserts assets from
a GeoJSON **FeatureCollection**, a single **Feature**, or a bare **geometry**. It
uses the *same* mapping contract as the QUERY source, expressed via Feature
`properties`:

- `geometry` → `geometry_geojson`.
- reserved property names (case-insensitive) → columns: `NAME`, `DESCRIPTION`,
  `FOLDER_NAME`, `VISIBILITY`, `DISPLAY_ORDER`, `ALTITUDE_MODE`, `EXTRUDE`,
  `TESSELLATE`, `ICON_HREF`, `ICON_SCALE`, `LABEL_COLOR`, `LABEL_SCALE`,
  `LINE_COLOR`, `LINE_WIDTH`, `POLY_COLOR`, `POLY_FILL`, `POLY_OUTLINE`.
- every other property → `extended_data` JSON (→ `<ExtendedData>` at render time).

This is the external counterpart to the internal QUERY source: same contract, same
render core, only the ingestion channel differs.

## Geometry

- Coordinates are **lon/lat** (longitude = X), SRID **4326**.
- `geometry_sdo` is converted with `SDO_UTIL.TO_KMLGEOMETRY`; `geometry_geojson`
  is first converted with `SDO_UTIL.FROM_GEOJSON`. **Oracle Spatial/Locator is
  required, and `FROM_GEOJSON` is a 19c feature — hence KMLeon's 19c floor.**
- Supported geometry types are whatever `SDO_UTIL.TO_KMLGEOMETRY` supports
  (points, lines, polygons, and their multi-/collection forms).

## Colors

KML stores colors as **`aabbggrr`** (alpha, blue, green, red) — *not* `#RRGGBB`.
`PCK_KML_ENGINE.rgba_to_kml('FF8800')` → `ff0088ff`; pass alpha 0–255 as the
second argument. Store the result directly in the `*_color` columns.

## Styling model

Styles are emitted **inline** per `<Placemark>` (no shared `<Style>`/`styleUrl`).
Simple and fully generic; trades file size for simplicity on large exports.

## Known limitations / future work

- **Placement modifiers** (`altitude_mode` / `extrude` / `tessellate`) are injected
  into the geometry output. They affect **3D viewers only** (Google Earth, Cesium);
  2D viewers ignore them, and `altitude_mode`/`extrude` need Z-bearing geometry to
  be meaningful. `GEOMETRY_KML` passthrough is left untouched (caller-controlled).
- **Folders**: single level only.
- **Inline styles**: no shared `<Style>` de-duplication yet.
- **KMZ**: relies on `APEX_ZIP`; swap in a pure-PL/SQL zipper if APEX is absent.
- **ExtendedData**: values read as strings via `JSON_OBJECT_T`; malformed JSON
  silently omits the block.
