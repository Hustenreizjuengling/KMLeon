--------------------------------------------------------------------------------
-- KMLeon :: master installer
--------------------------------------------------------------------------------
-- Run from this directory (sql/) as the schema that will own KMLeon, e.g.:
--   sqlplus kmleon/****@db @install.sql
--   -- or in SQLcl:  sql kmleon/****@db @install.sql
--
-- Requires Oracle 19c with Spatial/Locator (SDO_UTIL); GeoJSON input uses
-- SDO_UTIL.FROM_GEOJSON (19c). APEX (APEX_ZIP) is only
-- needed for KMZ output. Re-running on an existing install: @uninstall.sql first
-- (table DDL is not CREATE OR REPLACE).
--------------------------------------------------------------------------------

set define off
set serveroutput on size unlimited
set echo off
whenever sqlerror continue

prompt ============================================================
prompt  KMLeon install
prompt ============================================================

prompt -- table KML_LOG
@@ddl/tables/kml_log.sql
prompt -- table KML_JOBS
@@ddl/tables/kml_jobs.sql
prompt -- table KML_JOB_ASSETS
@@ddl/tables/kml_job_assets.sql

prompt -- package PCK_KML_LOG
@@packages/pck_kml_log.sql
show errors

prompt -- package PCK_KML_JOBS_DML
@@packages/pck_kml_jobs_dml.sql
show errors

prompt -- package PCK_KML_JOB_ASSETS_DML
@@packages/pck_kml_job_assets_dml.sql
show errors

prompt -- package PCK_KML_KMZ
@@packages/pck_kml_kmz.sql
show errors

prompt -- package PCK_KML_ENGINE
@@packages/pck_kml_engine.sql
show errors

prompt -- package PCK_KML_JOB_API
@@packages/pck_kml_job_api.sql
show errors

prompt
prompt -- Object status (anything not VALID needs attention):
column object_name format a28
column object_type format a13
select object_name, object_type, status
  from user_objects
 where (object_name like 'KML\_%' escape '\' or object_name like 'PCK\_KML%' escape '\')
 order by object_type, object_name;

prompt
prompt KMLeon installed. Enable the scheduler with:  @scheduler/010_scheduler.sql
prompt ============================================================
