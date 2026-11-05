--------------------------------------------------------------------------------
-- KMLeon :: smoke test - re-run guards (claim + empty-rerun protection)
--------------------------------------------------------------------------------
-- Asserts the run_job guards introduced by the code review:
--   1) Re-running an ASSETS job whose inputs were auto-cleaned after success
--      FAILs with a clear message (-20816) and KEEPS the previous result.
--   2) A job already RUNNING (in another session) is not re-processed: the
--      claim returns 0 and run_job skips with a WARN.
-- Temporarily forces DELETE_ASSETS_AFTER_SUCCESS=Y and restores it afterwards.
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job  number;
  l_a    number;
  l_row  kml_jobs%rowtype;
  l_prev boolean;
begin
  -- deterministic auto-cleanup for this test (restored at the end)
  l_prev := pck_kml_config_dml.get_boolean('DELETE_ASSETS_AFTER_SUCCESS', true);
  pck_kml_config_dml.set_boolean('DELETE_ASSETS_AFTER_SUCCESS', true);
  commit;

  l_job := pck_kml_job_api.create_job(
             p_document_name => 'Rerun smoke test',
             p_output_format => 'KML');
  l_a := pck_kml_job_api.add_asset(
           p_job_id           => l_job,
           p_geometry_geojson => to_clob('{"type":"Point","coordinates":[13.405,52.52]}'),
           p_name             => 'Berlin');
  commit;

  pck_kml_job_api.run_now(l_job);
  l_row := pck_kml_jobs_dml.get(l_job);
  if l_row.status != 'COMPLETED' or nvl(dbms_lob.getlength(l_row.result_kml), 0) = 0 then
    raise_application_error(-20999, 'rerun smoke FAILED: first run did not complete');
  end if;
  dbms_output.put_line('first run   : COMPLETED, ' || dbms_lob.getlength(l_row.result_kml) || ' chars');

  --- 1) re-run after auto-cleanup: clear failure, previous result preserved ----
  pck_kml_job_api.run_now(l_job);
  l_row := pck_kml_jobs_dml.get(l_job);
  if l_row.status != 'FAILED' or instr(l_row.error_message, 'no input rows') = 0 then
    raise_application_error(-20999, 'rerun smoke FAILED: empty re-run was not blocked (status '
      || l_row.status || ')');
  end if;
  if nvl(dbms_lob.getlength(l_row.result_kml), 0) = 0 then
    raise_application_error(-20999, 'rerun smoke FAILED: previous result was lost');
  end if;
  dbms_output.put_line('empty rerun : blocked (-20816), previous result preserved');

  --- 2) claim guard: a RUNNING job is not re-processed -------------------------
  pck_kml_jobs_dml.set_status(l_job, 'RUNNING');
  commit;
  pck_kml_job_api.run_now(l_job);   -- claim = 0 -> skipped with a WARN
  l_row := pck_kml_jobs_dml.get(l_job);
  if l_row.status != 'RUNNING' then
    raise_application_error(-20999, 'rerun smoke FAILED: RUNNING job was re-processed (status '
      || l_row.status || ')');
  end if;
  dbms_output.put_line('claim guard : RUNNING job skipped');

  --- cleanup + restore setting ------------------------------------------------
  pck_kml_jobs_dml.del(l_job);
  pck_kml_config_dml.set_boolean('DELETE_ASSETS_AFTER_SUCCESS', l_prev);
  commit;
  dbms_output.put_line('rerun smoke test OK (job cleaned up, setting restored)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_rerun')]'; exception when others then null; end;
end;
/
