<p align="center">
  <img src="docs/assets/MayfE.jpg" alt="KMLeon — Oracle Database KML/KMZ Generator — From Database to Earth" width="100%">
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/Oracle-19c-F80000?logo=oracle&logoColor=white" alt="Oracle 19c">
  <img src="https://img.shields.io/badge/PL%2FSQL-pure-1f6e4f" alt="Pure PL/SQL">
  <img src="https://img.shields.io/badge/runtime-none-2b6cb0" alt="No external runtime">
  <img src="https://img.shields.io/badge/output-KML%20%2F%20KMZ-22d3ee" alt="KML / KMZ">
</p>

<p align="center">
  <b>A generic, job-based KML/KMZ generator that runs entirely inside an Oracle database.</b><br>
  Your application decides <i>what</i> to map; KMLeon generically turns rows into KML/KMZ — no external runtime.
</p>

---

## Contents

- [Why KMLeon](#why-kmleon)
- [How it works](#how-it-works)
- [Components](#components)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [Feature mapping contract](#feature-mapping-contract)
- [Conventions](#conventions)
- [Roadmap](#roadmap)
- [License](#license)

## Why KMLeon

- **Pure PL/SQL, no moving parts.** Nothing to deploy outside the database — jobs are
  drained by a `DBMS_SCHEDULER` dispatcher (or run synchronously).
- **Generic.** KMLeon knows nothing about your domain. You supply geometries + metadata;
  it produces standards-compliant KML/KMZ.
- **Three ways to feed it, one render core:**
  - **Assets** — rows in a table (great for app-managed features).
  - **Query** — store a `SELECT`; it’s executed and **streamed** to KML at job time
    (the slow data-fetch runs *inside* the async job).
  - **GeoJSON** — push a FeatureCollection from outside (e.g. APEX REST).
- **Variable metadata per feature** — `name`, `description` (HTML balloon), and any extra
  attributes become `<ExtendedData>` automatically.
- **Disciplined data layer** — every table is written only through its DML package, with
  central logging and uniform audit columns.

## How it works

```
  create_job + add_asset ──┐  ASSETS : app fills KML_JOB_ASSETS
  create_job_from_query  ──┤  QUERY  : app stores a SELECT (streamed at run time)
  add_features_geojson   ──┘  GeoJSON: app pushes a FeatureCollection
                             │
                             ▼
                    PCK_KML_ENGINE.run_job ───────► result_kml (CLOB)
                       ├─ SDO / GeoJSON → KML                  or
                       └─ PCK_KML_KMZ.zip_kml ──────► result_kmz (BLOB)

        DBMS_SCHEDULER (KMLEON_DISPATCHER) ──► PCK_KML_ENGINE.process_pending
```

Job lifecycle: `DRAFT → PENDING → RUNNING → COMPLETED | FAILED | CANCELLED`.

## Components

| Object | Role |
|---|---|
| `KML_JOBS` | one row per export request + result + status (`PCK_KML_JOBS_DML`) |
| `KML_JOB_ASSETS` | one row per feature: geometry + metadata + style (`PCK_KML_JOB_ASSETS_DML`) |
| `KML_LOG` | central log (`PCK_KML_LOG`) |
| `PCK_KML_ENGINE` | the generic generator: geometry→KML, assembly, execution, dispatcher |
| `PCK_KML_KMZ` | KMZ zipping (isolated `APEX_ZIP` dependency) |
| `PCK_KML_JOB_API` | optional convenience wrapper |

## Requirements

- **Oracle Database 19c** — identity columns, native `JSON_OBJECT_T`/`JSON_ELEMENT_T`,
  and `SDO_UTIL.FROM_GEOJSON` (a 19c addition, hence the floor).
- **Oracle Spatial / Locator** (`SDO_UTIL`) — geometry conversion: `TO_KMLGEOMETRY`
  (KML out) and `FROM_GEOJSON` (GeoJSON in, **19c**).
- **APEX_ZIP** (ships with Oracle APEX) — only for `KMZ` output. Without it, `KML` still
  works and KMZ jobs fail with a clear message.

## Install

```sql
-- from the sql/ directory, as the schema that will own KMLeon
sqlplus kmleon/****@db @install.sql
@scheduler/010_scheduler.sql      -- enable the background dispatcher
```

Remove everything with `@uninstall.sql`. Smoke tests live in [`tests/`](tests).

## Usage

> The `PCK_KML_JOB_API` calls below are optional sugar over the DML packages — you may call
> those directly, but **never** write the tables with raw INSERT/UPDATE/DELETE.

<details open>
<summary><b>1 · App-managed features (ASSETS)</b></summary>

```sql
declare
  l_job number;
  l_a   number;
begin
  l_job := pck_kml_job_api.create_job('My export', p_output_format => 'KMZ',
             p_user_tab => 'APP_USERS', p_user_id => '42');

  l_a := pck_kml_job_api.add_asset(l_job,
           p_geometry_geojson => '{"type":"Point","coordinates":[13.405,52.52]}',
           p_name             => 'Berlin',
           p_extended_data    => '{"country":"DE"}',     -- shown in the balloon
           p_icon_scale       => 1.2);

  -- ... or native SDO_GEOMETRY:
  l_a := pck_kml_job_api.add_asset(l_job,
           p_geometry_sdo => sdo_geometry(2001, 4326, sdo_point_type(8.68,50.11,null), null, null),
           p_name         => 'Frankfurt');

  commit;
  pck_kml_job_api.submit_job(l_job);     -- dispatcher runs it; or run_now(l_job)
end;
/
```
</details>

<details>
<summary><b>2 · Query-driven, streamed (QUERY)</b></summary>

For large or slow exports, store a `SELECT` on the job. The dispatcher runs it *inside* the
job and streams each row straight to KML — **no assets persisted**. Column **aliases** drive
the output.

```sql
declare
  l_job number;
begin
  l_job := pck_kml_job_api.create_job_from_query(
    p_document_name => 'Stores by region',
    p_output_format => 'KMZ',
    p_source_binds  => '{"region":"DE"}',            -- bound as :region
    p_source_query  => q'[
        select shape       as geometry,              -- SDO_GEOMETRY column
               store_name  as name,
               region      as folder_name,
               opened_on   as opening_date,          -- unknown alias -> ExtendedData
               :region     as queried_region
          from stores
         where region = :region
         order by region                             -- ORDER BY folder to group
      ]');
  commit;
  pck_kml_job_api.submit_job(l_job);
end;
/
```

Pass `p_source_mode => 'MATERIALIZE'` to instead write rows into `KML_JOB_ASSETS` first and
then render — useful when you want the result persisted/inspectable/retryable. Streaming is
the lighter default.

> ⚠️ The query is dynamic SQL run with **this schema’s privileges** in the dispatcher (the
> requester’s context is gone). Only trusted apps may enqueue `QUERY` jobs, and **all
> parameters must be binds** — never string-concatenated.
</details>

<details>
<summary><b>3 · External push via GeoJSON (APEX REST)</b></summary>

When features come from outside the database, the client pushes them. Use an `ASSETS` job
plus `add_features_geojson`, which accepts a FeatureCollection (or a single Feature / bare
geometry) and bulk-inserts assets using the **same mapping contract**.

```sql
declare
  l_job number;
  l_n   number;
begin
  l_job := pck_kml_job_api.create_job('External upload', p_output_format => 'KMZ');
  l_n := pck_kml_job_api.add_features_geojson(l_job, q'[
    {"type":"FeatureCollection","features":[
      {"type":"Feature",
       "geometry":{"type":"Point","coordinates":[13.405,52.52]},
       "properties":{"NAME":"Berlin","FOLDER_NAME":"Cities","country":"DE"}}
    ]}]');
  commit;
  pck_kml_job_api.submit_job(l_job);
end;
/
```

A typical APEX REST surface:

```
GET    jobs                 list jobs
POST   jobs                 create an ASSETS job (JSON body)            -> DRAFT
POST   jobs/{id}/features   add_features_geojson (GeoJSON body)         [ASSETS]
POST   jobs/{id}/submit     submit_job                                  -> PENDING
POST   jobs/{id}/run        run synchronously now
POST   jobs/{id}/cancel     cancel a DRAFT/PENDING job
GET    jobs/{id}            status + metadata
GET    jobs/{id}/result     download the KMZ/KML
```

A **ready-to-run ORDS script** that creates exactly these endpoints (via the ORDS
PL/SQL API — no manual clicking) lives at
[`sql/ords/010_rest_api.sql`](sql/ords/010_rest_api.sql). Run it in **APEX → SQL
Workshop → SQL Scripts**. The `QUERY` source is deliberately **not** exposed over
REST; secure the module before using it (see the script's header).
</details>

## Feature mapping contract

The internal `QUERY` source (SQL column aliases) and the external GeoJSON source (Feature
`properties`) share one contract — reserved names map to roles, **everything else becomes an
`<ExtendedData>` property**:

| Role | Reserved name(s) |
|---|---|
| Geometry | `GEOMETRY` / `GEOMETRY_SDO`, `GEOMETRY_GEOJSON`, `GEOMETRY_KML` |
| Placemark | `NAME`, `DESCRIPTION`, `FOLDER_NAME`, `VISIBILITY` |
| Style | `ICON_HREF`, `ICON_SCALE`, `LABEL_COLOR`, `LABEL_SCALE`, `LINE_COLOR`, `LINE_WIDTH`, `POLY_COLOR`, `POLY_FILL`, `POLY_OUTLINE` |
| Placement | `ALTITUDE_MODE`, `EXTRUDE`, `TESSELLATE` |
| Extra | `EXTENDED_DATA` (a JSON object), plus *any other column/property* |

- Geometry is **lon/lat** (X = longitude), SRID **4326**.
- **Colors** are KML `aabbggrr` hex — convert from `RRGGBB` with
  `PCK_KML_ENGINE.rgba_to_kml('FF0000')` (+ optional 0–255 alpha).
- `FOLDER_NAME` groups features into a single-level `<Folder>` (order by it for grouping).

See [`docs/data-model.md`](docs/data-model.md) for the full column reference and limitations.

## Conventions

- **Packages are named `PCK_*`.**
- **No direct DML on tables** — every table is written only through its DML package.
- **Central logging** via `PCK_KML_LOG` (autonomous transaction, survives rollback).
- **Audit columns** `created_at / created_by / updated_at / updated_by` on every table,
  auto-stamped by the DML package when passed NULL.

## Roadmap

- Nested `<Folder>` hierarchies.
- Shared `<Style>` de-duplication (`styleUrl`) for large exports.
- Pure-PL/SQL ZIP fallback so KMZ works without APEX.
- ORDS/APEX REST handlers and a utPLSQL test suite.

## License

[MIT](LICENSE) © KMLeon contributors.
