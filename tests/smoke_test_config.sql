--------------------------------------------------------------------------------
-- KMLeon :: smoke test - config & maintenance
--------------------------------------------------------------------------------
-- Exercises PCK_KML_CONFIG_DML (typed get/set, metric stamping) and
-- PCK_KML_MAINTENANCE (config-driven purge + apply_schedule). Non-destructive:
-- it sets retention very high so no real jobs are deleted. Run after install.sql.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set lines 200

declare
  l_str     varchar2(200);
  l_num     number;
  l_ts      timestamp;
  l_deleted pls_integer;
begin
  --- typed set / get round-trip ----------------------------------------------
  pck_kml_config_dml.set_string ('SMOKE_STR', 'hello');
  pck_kml_config_dml.set_number ('SMOKE_NUM', 42);
  pck_kml_config_dml.set_boolean('SMOKE_BOOL', true);
  commit;

  l_str := pck_kml_config_dml.get_string('SMOKE_STR');
  l_num := pck_kml_config_dml.get_number('SMOKE_NUM');
  dbms_output.put_line('get_string  : ' || l_str);
  dbms_output.put_line('get_number  : ' || l_num);
  dbms_output.put_line('get_boolean : ' || case when pck_kml_config_dml.get_boolean('SMOKE_BOOL') then 'TRUE' else 'FALSE' end);
  dbms_output.put_line('missing key : ' || nvl(pck_kml_config_dml.get_string('NOPE', '<default>'), '<null>'));

  --- metric helper ------------------------------------------------------------
  pck_kml_config_dml.touch_metric('SMOKE_METRIC_TS');
  commit;
  l_ts := pck_kml_config_dml.get_timestamp('SMOKE_METRIC_TS');
  dbms_output.put_line('touched ts  : ' || to_char(l_ts, 'YYYY-MM-DD HH24:MI:SS'));

  --- defaults present ---------------------------------------------------------
  dbms_output.put_line('cleanup en. : ' || case when pck_kml_config_dml.get_boolean('CLEANUP_ENABLED') then 'Y' else 'N' end);
  dbms_output.put_line('statuses    : ' || pck_kml_config_dml.get_string('CLEANUP_STATUSES'));

  --- purge dry-run: retention 100000 days => deletes nothing ------------------
  l_deleted := pck_kml_jobs_dml.purge('COMPLETED,CANCELLED', 100000);
  rollback;   -- undo even the (expected zero) delete, just in case
  dbms_output.put_line('purge(dry)  : deleted=' || l_deleted || ' (expected 0)');

  --- apply_schedule reads config and (re)creates/drops the job ---------------
  pck_kml_maintenance.apply_schedule;
  dbms_output.put_line('apply_sched : ok');

  --- assertions: fail hard so scripted runs detect regressions ---------------
  if l_str != 'hello' or l_num != 42
     or not pck_kml_config_dml.get_boolean('SMOKE_BOOL')
     or nvl(pck_kml_config_dml.get_string('NOPE', '<default>'), 'x') != '<default>'
     or l_ts is null
     or l_deleted != 0 then
    raise_application_error(-20999, 'config smoke FAILED (see output above)');
  end if;

  --- clean up the smoke keys via the DML package (no direct table DML) --------
  pck_kml_config_dml.del('SMOKE_STR');
  pck_kml_config_dml.del('SMOKE_NUM');
  pck_kml_config_dml.del('SMOKE_BOOL');
  pck_kml_config_dml.del('SMOKE_METRIC_TS');
  commit;
  if pck_kml_config_dml.get_string('SMOKE_STR', '<gone>') != '<gone>' then
    raise_application_error(-20999, 'config smoke FAILED: del did not remove the key');
  end if;

  dbms_output.put_line('--------------------------------------------------');
  dbms_output.put_line('config smoke test OK');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_config')]'; exception when others then null; end;
end;
/

prompt
prompt -- current KML_CONFIG contents:
column config_key      format a32
column category        format a8
column data_type       format a9
column value_string    format a24
column description     format a44 word_wrapped
select config_key, category, data_type, value_string, value_number,
       to_char(value_timestamp, 'YYYY-MM-DD HH24:MI') as value_timestamp
  from kml_config
 order by category, config_key;
