--------------------------------------------------------------------------------
-- KMLeon :: smoke test - release stamp
--------------------------------------------------------------------------------
-- install.sql / update.sql stamp PCK_KML_ENGINE.gc_version into KML_CONFIG.
-- A mismatch means the scripts were not (re)run after deploying new packages.
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_cfg varchar2(40) := pck_kml_config_dml.get_string('KMLEON_VERSION');
  l_ts  timestamp    := pck_kml_config_dml.get_timestamp('METRIC_LAST_INSTALL_AT');
  l_inv pls_integer;
begin
  dbms_output.put_line('code    : ' || pck_kml_engine.version);
  dbms_output.put_line('config  : ' || nvl(l_cfg, '<missing>'));
  dbms_output.put_line('stamped : ' || to_char(l_ts, 'YYYY-MM-DD HH24:MI:SS'));
  if not regexp_like(pck_kml_engine.version, '^\d+\.\d+\.\d+$') then
    raise_application_error(-20999, 'version smoke FAILED: gc_version is not semver');
  end if;
  if l_cfg is null or l_cfg != pck_kml_engine.version or l_ts is null then
    raise_application_error(-20999, 'version smoke FAILED: KML_CONFIG stamp missing or stale -- run update.sql');
  end if;
  select count(*) into l_inv from user_objects
   where (object_name like 'KML\_%' escape '\' or object_name like 'PCK\_KML%' escape '\')
     and status <> 'VALID';
  if l_inv > 0 then
    raise_application_error(-20999, 'version smoke FAILED: ' || l_inv || ' invalid KMLeon object(s)');
  end if;
  dbms_output.put_line('version smoke test OK (all objects valid)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_version')]'; exception when others then null; end;
end;
/
