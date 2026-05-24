--------------------------------------------------------------------------------
-- KMLeon :: in-place update (non-destructive)
--------------------------------------------------------------------------------
-- Brings an existing KMLeon install up to date WITHOUT dropping data:
--   * creates the new KML_CONFIG table (if it is not there yet),
--   * (re)compiles every package in dependency order (CREATE OR REPLACE),
--   * seeds any missing default config rows (existing values are preserved).
--
-- Safe to re-run. The "table already exists" error on KML_CONFIG (when it is
-- already present) is expected and ignored (whenever sqlerror continue).
--
-- Run from this directory (sql/) as the schema that owns KMLeon, e.g.:
--   sqlplus kmleon/****@db @update.sql
--   -- or in SQLcl:  sql kmleon/****@db @update.sql
--
-- This does NOT touch existing tables or the scheduler jobs. To (re)apply the
-- cleanup schedule afterwards, run:  @scheduler/020_maintenance.sql
--------------------------------------------------------------------------------

set define off
set serveroutput on size unlimited
set echo off
whenever sqlerror continue

prompt ============================================================
prompt  KMLeon update
prompt ============================================================

prompt -- table KML_CONFIG (new; "already exists" is fine on re-run)
@@ddl/tables/kml_config.sql

prompt -- (re)compile packages in dependency order
prompt -- PCK_KML_LOG
@@packages/pck_kml_log.sql
show errors
prompt -- PCK_KML_CONFIG_DML
@@packages/pck_kml_config_dml.sql
show errors
prompt -- PCK_KML_JOBS_DML
@@packages/pck_kml_jobs_dml.sql
show errors
prompt -- PCK_KML_JOB_ASSETS_DML
@@packages/pck_kml_job_assets_dml.sql
show errors
prompt -- PCK_KML_KMZ
@@packages/pck_kml_kmz.sql
show errors
prompt -- PCK_KML_NOTIFY
@@packages/pck_kml_notify.sql
show errors
prompt -- PCK_KML_ENGINE
@@packages/pck_kml_engine.sql
show errors
prompt -- PCK_KML_JOB_API
@@packages/pck_kml_job_api.sql
show errors
prompt -- PCK_KML_MAINTENANCE
@@packages/pck_kml_maintenance.sql
show errors

prompt -- seed default config rows (idempotent; preserves existing values)
begin
  pck_kml_config_dml.init_defaults;
  commit;
end;
/

prompt
prompt -- Object status (anything not VALID needs attention):
column object_name format a28
column object_type format a13
select object_name, object_type, status
  from user_objects
 where (object_name like 'KML\_%' escape '\' or object_name like 'PCK\_KML%' escape '\')
 order by object_type, object_name;

prompt
prompt KMLeon updated. New global setting DELETE_ASSETS_AFTER_SUCCESS defaults to ON.
prompt   - (optional) (re)apply cleanup schedule:  @scheduler/020_maintenance.sql
prompt ============================================================
