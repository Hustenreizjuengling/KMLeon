--------------------------------------------------------------------------------
-- KMLeon :: master installer
--------------------------------------------------------------------------------
-- Run from this directory (sql/) as the schema that will own KMLeon, e.g.:
--   sqlplus kmleon/****@db @install.sql
--   -- or in SQLcl:  sql kmleon/****@db @install.sql
--
-- Requires Oracle 19c with Spatial/Locator (SDO_UTIL); GeoJSON input uses
-- SDO_UTIL.FROM_GEOJSON (19c). The Oracle JVM is NOT needed (KML geometry is
-- written by PCK_KML_GEOM in pure PL/SQL). APEX (APEX_ZIP) is only
-- needed for KMZ output. The public access_key token uses DBMS_CRYPTO (called
-- dynamically; without the grant it falls back to weaker GUID entropy + WARN).
-- Recommended (run as SYS):  grant execute on sys.dbms_crypto to <schema>;
-- Re-running on an existing install: @uninstall.sql first
-- (table DDL is not CREATE OR REPLACE).
--
-- The script runs with "whenever sqlerror continue": an early failure does NOT
-- stop it. The install only counts as successful when the closing object-status
-- query reports every object VALID.
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
prompt -- table KML_CONFIG
@@ddl/tables/kml_config.sql
prompt -- table KML_JOBS
@@ddl/tables/kml_jobs.sql
prompt -- table KML_JOB_ASSETS
@@ddl/tables/kml_job_assets.sql

prompt -- package PCK_KML_LOG
@@packages/pck_kml_log.sql
show errors

prompt -- package PCK_KML_CONFIG_DML
@@packages/pck_kml_config_dml.sql
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

prompt -- package PCK_KML_NOTIFY
@@packages/pck_kml_notify.sql
show errors

prompt -- package PCK_KML_GEOM
@@packages/pck_kml_geom.sql
show errors

prompt -- package PCK_KML_ENGINE
@@packages/pck_kml_engine.sql
show errors

prompt -- package PCK_KML_JOB_API
@@packages/pck_kml_job_api.sql
show errors

prompt -- package PCK_KML_MAINTENANCE
@@packages/pck_kml_maintenance.sql
show errors

prompt -- seed default config rows (idempotent; preserves existing values)
begin
  pck_kml_config_dml.init_defaults;
  commit;
end;
/

prompt -- stamp the installed release (KML_CONFIG: KMLEON_VERSION / METRIC_LAST_INSTALL_AT)
begin
  pck_kml_config_dml.set_string('KMLEON_VERSION', pck_kml_engine.gc_version, 'METRIC');
  pck_kml_config_dml.touch_metric('METRIC_LAST_INSTALL_AT');
  commit;
  dbms_output.put_line('KMLeon version ' || pck_kml_engine.gc_version);
end;
/


prompt -- recompile dependants left INVALID by the package changes (e.g. PCK_KMLEON_TOOLS)
begin
  for r in (select object_name, object_type
              from user_objects
             where status <> 'VALID'
               and (object_name like 'KML\_%' escape '\' or object_name like 'PCK\_KML%' escape '\')
             order by case object_type when 'PACKAGE' then 1 when 'PACKAGE BODY' then 2 else 3 end)
  loop
    begin
      execute immediate 'alter ' || case r.object_type when 'PACKAGE BODY' then 'package' else lower(r.object_type) end
                        || ' ' || r.object_name || ' compile' || case r.object_type when 'PACKAGE BODY' then ' body' end;
    exception when others then null;   -- the status query below reports what is still invalid
    end;
  end loop;
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

select value_string as kmleon_version from kml_config where config_key = 'KMLEON_VERSION';

prompt -- hard check: fail loudly (and with a failure exit code) when anything is invalid
whenever sqlerror exit failure
declare
  l_inv pls_integer;
begin
  select count(*) into l_inv from user_objects
   where (object_name like 'KML\_%' escape '\' or object_name like 'PCK\_KML%' escape '\')
     and status <> 'VALID';
  if l_inv > 0 then
    raise_application_error(-20999, 'KMLeon INSTALL INCOMPLETE: ' || l_inv || ' invalid object(s) -- see the status list above');
  end if;
end;
/
whenever sqlerror continue

prompt
prompt KMLeon installed.
prompt   Run jobs with PCK_KML_JOB_API.run_async (own background job) or run_now (sync).
prompt   - optional polled dispatcher (created DISABLED):  @scheduler/010_scheduler.sql
prompt   - cleanup (config-driven purge):                 @scheduler/020_maintenance.sql
prompt ============================================================
