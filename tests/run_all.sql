--------------------------------------------------------------------------------
-- KMLeon :: run every smoke test and print a pass/fail summary
--------------------------------------------------------------------------------
-- Run from this directory as the KMLeon schema (SQLcl or SQL*Plus):
--   sql kmleon/****@db @run_all.sql
-- Every script asserts hard (raise -20999) and, on success, marks itself in the
-- temporary table KML_TEST_RESULTS (the mark is a no-op when a script is run on
-- its own). The summary lists PASS/FAIL per script, drops the table and exits
-- with a failure code when anything failed -- suitable for CI.
-- Needs: KMLeon installed (install.sql / update.sql), APEX for the KMZ, editor
-- URL and toolkit tests (setup.sql), Spatial. No Oracle JVM required.
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited
set feedback off
set lines 200
whenever sqlerror continue

begin
  execute immediate 'create table kml_test_results (test varchar2(100) primary key, run_at timestamp default systimestamp)';
exception when others then null;   -- left over from an aborted run
end;
/
truncate table kml_test_results;

prompt ===== smoke_test
@@smoke_test.sql
prompt ===== smoke_test_config
@@smoke_test_config.sql
prompt ===== smoke_test_editor_url
@@smoke_test_editor_url.sql
prompt ===== smoke_test_errors
@@smoke_test_errors.sql
prompt ===== smoke_test_extdata
@@smoke_test_extdata.sql
prompt ===== smoke_test_geojson
@@smoke_test_geojson.sql
prompt ===== smoke_test_geom
@@smoke_test_geom.sql
prompt ===== smoke_test_kmz
@@smoke_test_kmz.sql
prompt ===== smoke_test_notify
@@smoke_test_notify.sql
prompt ===== smoke_test_public
@@smoke_test_public.sql
prompt ===== smoke_test_query
@@smoke_test_query.sql
prompt ===== smoke_test_rerun
@@smoke_test_rerun.sql
prompt ===== smoke_test_stylemap
@@smoke_test_stylemap.sql
prompt ===== smoke_test_version
@@smoke_test_version.sql
prompt ===== smoke_test_zip
@@smoke_test_zip.sql

prompt
prompt ===== SUMMARY
whenever sqlerror exit failure
declare
  type t_names is table of varchar2(100);
  l_expected t_names := t_names('smoke_test', 'smoke_test_config', 'smoke_test_editor_url', 'smoke_test_errors', 'smoke_test_extdata', 'smoke_test_geojson', 'smoke_test_geom', 'smoke_test_kmz', 'smoke_test_notify', 'smoke_test_public', 'smoke_test_query', 'smoke_test_rerun', 'smoke_test_stylemap', 'smoke_test_version', 'smoke_test_zip');
  l_n        pls_integer;
  l_fail     pls_integer := 0;
begin
  for i in 1 .. l_expected.count loop
    select count(*) into l_n from kml_test_results where test = l_expected(i);
    dbms_output.put_line(case when l_n = 1 then 'PASS  ' else 'FAIL  ' end || l_expected(i));
    if l_n = 0 then
      l_fail := l_fail + 1;
    end if;
  end loop;
  execute immediate 'drop table kml_test_results purge';
  if l_fail > 0 then
    raise_application_error(-20999, l_fail || ' of ' || l_expected.count || ' test scripts FAILED');
  end if;
  dbms_output.put_line('ALL ' || l_expected.count || ' TEST SCRIPTS PASSED (KMLeon ' || pck_kml_engine.version || ')');
end;
/
exit
