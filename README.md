# KMLeon

A generic, job-based mechanism for generating **KML / KMZ** files **inside an Oracle
database**. KMLeon knows nothing about your domain: the consuming application
decides *what* to show by inserting rows; KMLeon generically turns those rows into
KML/KMZ.

Pure PL/SQL — no external runtime. Jobs are produced into two tables and drained
by an Oracle `DBMS_SCHEDULER` dispatcher (or run synchronously on demand).

## How it works

```
  application                  KMLeon (PL/SQL)                 output
  -----------                  ---------------                 ------
  create_job + add_asset ─┐  (ASSETS: app fills KML_JOB_ASSETS)
  create_job_from_query  ─┤  (QUERY:  app stores a SELECT, streamed at run time)
                          └─► PCK_KML_ENGINE.run_job ──► result_kml (CLOB)
        submit_job (PENDING)    ├─ SDO/GeoJSON → KML              or
                                └─ PCK_KML_KMZ.zip_kml ──► result_kmz (BLOB)
        DBMS_SCHEDULER  ──────► PCK_KML_ENGINE.process_pending
```

Two data sources per job: **`ASSETS`** (rows in `KML_JOB_ASSETS`) or **`QUERY`**
(a stored `SELECT` executed and streamed at run time — see below).

Job lifecycle: `DRAFT → PENDING → RUNNING → COMPLETED | FAILED | CANCELLED`.

## Conventions (project-wide)

- **Packages are named `PCK_*`.**
- **No direct DML on tables.** Every table is written *only* through its DML
  package (`PCK_KML_JOBS_DML`, `PCK_KML_JOB_ASSETS_DML`, `PCK_KML_LOG`). SELECTs
  may be direct.
- **Central logging** via `PCK_KML_LOG` (autonomous transaction, survives rollback).
- **Audit columns** `created_at / created_by / updated_at / updated_by` on every
  table, auto-stamped by the DML package when passed NULL.

## Components

| Object | Role |
|---|---|
| `KML_JOBS` | one row per export request + result + status (`PCK_KML_JOBS_DML`) |
| `KML_JOB_ASSETS` | one row per feature: geometry + metadata + style (`PCK_KML_JOB_ASSETS_DML`) |
| `KML_LOG` | central log (`PCK_KML_LOG`) |
| `PCK_KML_ENGINE` | the generic generator: geometry→KML, assembly, execution, dispatcher |
| `PCK_KML_KMZ` | KMZ zipping (isolated `APEX_ZIP` dependency) |
| `PCK_KML_JOB_API` | optional convenience wrapper (`create_job` / `add_asset` / `submit_job` / …) |

## Requirements

- Oracle Database **12.2+** (19c recommended) — identity columns, native
  `JSON_OBJECT_T`.
- **Oracle Spatial / Locator** (`SDO_UTIL`) — geometry conversion
  (`FROM_GEOJSON`, `TO_KMLGEOMETRY`).
- **APEX_ZIP** (ships with Oracle APEX) — only for `KMZ` output. Without it, `KML`
  output still works and KMZ jobs fail with a clear message.

## Install

```sql
-- from the sql/ directory, as the schema that will own KMLeon
sqlplus kmleon/****@db @install.sql
@scheduler/010_scheduler.sql   -- enable the background dispatcher
```

Remove everything with `@uninstall.sql`. Smoke test: `@../tests/smoke_test.sql`.

## Usage

```sql
declare
  l_job number;
  l_a   number;
begin
  l_job := pck_kml_job_api.create_job('My export', p_output_format => 'KMZ',
             p_user_tab => 'APP_USERS', p_user_id => '42');

  -- geometry as GeoJSON ...
  l_a := pck_kml_job_api.add_asset(l_job,
           p_geometry_geojson => '{"type":"Point","coordinates":[13.405,52.52]}',
           p_name             => 'Berlin',
           p_extended_data    => '{"country":"DE"}',   -- shown in the balloon
           p_icon_scale       => 1.2);

  -- ... or as native SDO_GEOMETRY
  l_a := pck_kml_job_api.add_asset(l_job,
           p_geometry_sdo => sdo_geometry(2001, 4326, sdo_point_type(8.68,50.11,null), null, null),
           p_name         => 'Frankfurt');

  commit;
  pck_kml_job_api.submit_job(l_job);   -- dispatcher runs it; or run_now(l_job)
end;
/

-- result later: get_kmz(:id) / get_kml(:id)
```

The API is optional sugar over the DML packages — you may call those directly,
but never write the tables with raw INSERT/UPDATE/DELETE.

### Query-driven (streaming) jobs

For large or slow exports you usually don't want to materialize assets up front.
A **`QUERY` job** stores a `SELECT` on the job; the dispatcher runs it *inside the
job* (so the slow data-fetch is asynchronous too) and streams each row straight to
KML — **no assets are written**. Column **aliases** drive the output:

```sql
declare
  l_job number;
begin
  l_job := pck_kml_job_api.create_job_from_query(
    p_document_name => 'Stores by region',
    p_output_format => 'KMZ',
    p_source_binds  => '{"region":"DE"}',          -- bound as :region
    p_source_query  => q'[
        select shape           as geometry,         -- SDO_GEOMETRY column
               store_name      as name,
               region          as folder_name,
               opened_on       as opening_date,     -- unknown alias -> ExtendedData
               :region         as queried_region
          from stores
         where region = :region
         order by region                            -- ORDER BY folder to group
      ]');
  commit;
  pck_kml_job_api.submit_job(l_job);   -- dispatcher streams it; or run_now(l_job)
end;
/
```

Recognized aliases: `GEOMETRY` (SDO) | `GEOMETRY_GEOJSON` | `GEOMETRY_KML`, plus
`NAME`, `DESCRIPTION`, `FOLDER_NAME`, `VISIBILITY`, `ICON_HREF`, `ICON_SCALE`,
`LABEL_COLOR`, `LABEL_SCALE`, `LINE_COLOR`, `LINE_WIDTH`, `POLY_COLOR`,
`POLY_FILL`, `POLY_OUTLINE`, `EXTENDED_DATA`. **Every other column becomes an
`<ExtendedData>` property** (alias = property name) — that's your "variable
metadata per feature".

The query is run via `DBMS_SQL` with **this schema's privileges** in the
dispatcher (the requester's context is gone), so only trusted apps may enqueue
`QUERY` jobs and **all parameters must be binds** (never string-concatenated).

By default a `QUERY` job **streams** (no assets persisted). Pass
`p_source_mode => 'MATERIALIZE'` to instead write each row into `KML_JOB_ASSETS`
(via the DML package) and then render — useful when you want the result
inspectable/retryable or audited. Streaming is the lighter default.

### External ingestion (APEX REST / GeoJSON)

When the features come from *outside* the database (e.g. an APEX RESTful
service), the client can't supply a query — it pushes geometries. Use an
**`ASSETS` job** plus `add_features_geojson`, which accepts a GeoJSON
FeatureCollection (or a single Feature / bare geometry) and bulk-inserts assets
using the **same mapping contract**: `geometry` → the feature geometry, reserved
`properties` names → columns, everything else → `<ExtendedData>`.

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
POST /jobs                 -> create_job  (or create_job_from_query)   -> DRAFT
POST /jobs/{id}/features   -> add_features_geojson(body)               [ASSETS]
POST /jobs/{id}/submit     -> submit_job                               -> PENDING
GET  /jobs/{id}            -> get_status
GET  /jobs/{id}/result     -> get_kmz / get_kml                        (BLOB/CLOB)
```

So the **mapping contract and render core are identical** whether features arrive
as a SQL query (internal) or as GeoJSON (external); only ingestion differs.

## Geometry & metadata

- Supply **GeoJSON** (`geometry_geojson`) *or* **`SDO_GEOMETRY`** (`geometry_sdo`)
  per asset; `SDO_GEOMETRY` wins if both are set. Coordinates are lon/lat (SRID 4326).
- Per-feature metadata surfaces in the KML: `name` → `<name>`, `description` →
  balloon (HTML allowed), `extended_data` (JSON object) → `<ExtendedData>`.
- **Colors** are KML `aabbggrr` hex. Convert from `RRGGBB` with
  `PCK_KML_ENGINE.rgba_to_kml('FF0000')` (+ optional 0–255 alpha).

See [`docs/data-model.md`](docs/data-model.md) for the full column reference and
known limitations.

## License

[MIT](LICENSE).
