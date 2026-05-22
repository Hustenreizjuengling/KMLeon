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
  PCK_KML_JOB_API.create_job ─┐
  PCK_KML_JOB_API.add_asset   ┘─► PCK_KML_ENGINE.run_job ──► result_kml (CLOB)
        submit_job (PENDING)        ├─ SDO/GeoJSON → KML            or
                                    └─ PCK_KML_KMZ.zip_kml ──► result_kmz (BLOB)
        DBMS_SCHEDULER  ──────────► PCK_KML_ENGINE.process_pending
```

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
