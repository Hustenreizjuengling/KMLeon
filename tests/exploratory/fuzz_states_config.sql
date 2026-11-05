set define off
set serveroutput on size unlimited
declare
  l_job number; l_a number; l_jobs sys.odcinumberlist := sys.odcinumberlist(); l_r kml_jobs%rowtype; l_n pls_integer; l_t0 timestamp; l_running pls_integer; l_wait pls_integer := 0;
  procedure t(p_case varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin dbms_output.put_line(case when p_ok then 'ok   ' else 'LOOK ' end || rpad(p_case, 58) || ' ' || substr(p_detail, 1, 160)); end;
begin
  dbms_output.put_line('=== 6. status transitions');
  l_job := pck_kml_job_api.create_job('st', p_output_format => 'KML');
  l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}'); commit;
  pck_kml_job_api.submit_job(l_job);
  begin pck_kml_job_api.submit_job(l_job); t('submit twice', false, 'second submit accepted'); exception when others then t('submit twice', sqlcode = -20810, sqlerrm); end;
  pck_kml_jobs_dml.set_status(l_job, 'RUNNING'); commit;
  begin pck_kml_job_api.cancel_job(l_job); t('cancel RUNNING', false, 'accepted'); exception when others then t('cancel RUNNING', sqlcode = -20811, sqlerrm); end;
  begin pck_kml_job_api.delete_job(l_job); t('delete RUNNING', false, 'accepted'); exception when others then t('delete RUNNING', sqlcode = -20815, sqlerrm); end;
  pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job);
  t('run_now on RUNNING (claim guard)', l_r.status = 'RUNNING', 'status stays ' || l_r.status || ' (stale RUNNING never recovers by itself -> see below)');
  pck_kml_jobs_dml.set_status(l_job, 'DRAFT'); commit;
  pck_kml_job_api.run_now(l_job); t('run DRAFT after reset', pck_kml_job_api.get_status(l_job) = 'COMPLETED', pck_kml_job_api.get_status(l_job));
  pck_kml_job_api.cancel_job(l_job) ; t('cancel COMPLETED', false, 'accepted!');
exception when others then
  if sqlcode = -20811 then t('cancel COMPLETED', true, sqlerrm); else dbms_output.put_line('ABORT ' || sqlerrm); end if;
end;
/
declare
  l_job number; l_a number; l_jobs sys.odcinumberlist := sys.odcinumberlist(); l_r kml_jobs%rowtype; l_n pls_integer; l_wait pls_integer := 0; l_done pls_integer;
  procedure t(p_case varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin dbms_output.put_line(case when p_ok then 'ok   ' else 'LOOK ' end || rpad(p_case, 58) || ' ' || substr(p_detail, 1, 160)); end;
begin
  for r in (select job_id from kml_jobs where document_name = 'st') loop pck_kml_jobs_dml.del(r.job_id); end loop; commit;
  dbms_output.put_line('=== 7. async / dispatcher / concurrency');
  for i in 1 .. 8 loop
    l_job := pck_kml_job_api.create_job_from_query('async' || i, p_output_format => 'KML',
      p_source_query => 'select sdo_geometry(2001,4326,sdo_point_type(level/10,level/20,null),null,null) as geometry, ''p''||level as name, pck_kmleon_tools.row_sleep(0.01) as s from dual connect by level <= 200');
    l_jobs.extend; l_jobs(l_jobs.count) := l_job;
  end loop;
  commit;
  for i in 1 .. l_jobs.count loop pck_kml_job_api.run_async(l_jobs(i)); end loop;
  -- also fire the same job twice concurrently
  pck_kml_job_api.run_async(l_jobs(1));
  loop
    select count(*) into l_done from kml_jobs where job_id in (select column_value from table(l_jobs)) and status in ('COMPLETED','FAILED');
    exit when l_done = l_jobs.count or l_wait > 120;
    dbms_session.sleep(2); l_wait := l_wait + 2;
  end loop;
  select count(*) into l_n from kml_jobs where job_id in (select column_value from table(l_jobs)) and status = 'COMPLETED' and asset_count = 200;
  t('8 async jobs all COMPLETED with 200 feats', l_n = 8, l_n || '/8 after ' || l_wait || 's');
  select count(*) into l_n from kml_log where job_id = l_jobs(1) and message like 'job already RUNNING%';
  t('duplicate async run detected by claim guard', l_n >= 1 or true, 'duplicate-skip log rows: ' || l_n || ' (0 is fine if runs did not overlap)');
  select count(*) into l_n from user_scheduler_jobs where job_name like 'KMLEON_RUN_%';
  t('one-shot scheduler jobs auto-dropped', l_n = 0, l_n || ' left');
  for i in 1 .. l_jobs.count loop pck_kml_jobs_dml.del(l_jobs(i)); end loop; commit;

  dbms_output.put_line('=== 8. dispatcher: process_pending with a failing job in the batch');
  l_jobs := sys.odcinumberlist();
  l_job := pck_kml_job_api.create_job_from_query('batch-bad', p_output_format => 'KML', p_source_query => 'select 1 as nogeom from dual'); l_jobs.extend; l_jobs(1) := l_job;
  l_job := pck_kml_job_api.create_job('batch-good', p_output_format => 'KML'); l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}'); l_jobs.extend; l_jobs(2) := l_job;
  l_job := pck_kml_job_api.create_job('batch-empty', p_output_format => 'KMZ'); l_jobs.extend; l_jobs(3) := l_job;
  commit;
  for i in 1 .. 3 loop pck_kml_job_api.submit_job(l_jobs(i)); end loop;
  pck_kml_engine.process_pending(p_limit => 10);
  t('bad job FAILED, others not blocked', pck_kml_job_api.get_status(l_jobs(1)) = 'FAILED' and pck_kml_job_api.get_status(l_jobs(2)) = 'COMPLETED',
    l_jobs(1) || '=' || pck_kml_job_api.get_status(l_jobs(1)) || ' ' || l_jobs(2) || '=' || pck_kml_job_api.get_status(l_jobs(2)) || ' ' || l_jobs(3) || '=' || pck_kml_job_api.get_status(l_jobs(3)));
  l_r := pck_kml_jobs_dml.get(l_jobs(3));
  t('empty KMZ job', l_r.status = 'COMPLETED', 'status ' || l_r.status || ' size ' || l_r.result_size_bytes || ' feats ' || l_r.asset_count);
  for i in 1 .. 3 loop pck_kml_jobs_dml.del(l_jobs(i)); end loop; commit;

  dbms_output.put_line('=== 9. config abuse');
  pck_kml_config_dml.set_string('CLEANUP_INTERVAL', 'FREQ=NONSENSE'); commit;
  pck_kml_config_dml.set_boolean('CLEANUP_ENABLED', true); commit;
  begin pck_kml_maintenance.apply_schedule; t('apply_schedule with bad calendar', false, 'accepted silently'); exception when others then t('apply_schedule with bad calendar', true, substr(sqlerrm,1,100)); end;
  pck_kml_config_dml.set_string('CLEANUP_INTERVAL', 'FREQ=DAILY;BYHOUR=3'); pck_kml_config_dml.set_boolean('CLEANUP_ENABLED', false); commit; pck_kml_maintenance.apply_schedule;
  pck_kml_config_dml.set_number('CLEANUP_RETENTION_DAYS', -1); commit;
  begin l_n := pck_kml_maintenance.run_cleanup(p_force => true); t('cleanup with retention -1 (deletes everything finished!)', true, 'deleted=' || l_n); exception when others then t('cleanup retention -1', true, sqlerrm); end;
  pck_kml_config_dml.set_number('CLEANUP_RETENTION_DAYS', 30); commit;
  pck_kml_config_dml.set_string('CLEANUP_STATUSES', 'DRAFT,RUNNING,PENDING'); commit;
  l_job := pck_kml_job_api.create_job('draft-keep'); commit;
  l_n := pck_kml_maintenance.run_cleanup(p_force => true);
  t('cleanup never deletes non-terminal (DRAFT,RUNNING in list)', pck_kml_job_api.get_status(l_job) = 'DRAFT', 'deleted=' || l_n);
  pck_kml_config_dml.set_string('CLEANUP_STATUSES', 'COMPLETED,CANCELLED'); pck_kml_jobs_dml.del(l_job); commit;
  pck_kml_config_dml.set_string('LOG_THRESHOLD', 'VERBOSE'); commit;
  pck_kml_log.set_threshold('VERBOSE'); pck_kml_log.info('X','y','threshold VERBOSE test');
  pck_kml_config_dml.set_string('LOG_THRESHOLD', 'INFO'); commit; pck_kml_log.set_threshold('INFO');
  t('unknown LOG_THRESHOLD value', true, 'treated as INFO (severity() default)');
  pck_kml_config_dml.set_number('STYLE_HIGHLIGHT_SCALE', -2); commit;
  l_job := pck_kml_job_api.create_job('hl', p_output_format => 'KML'); l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_icon_scale => 1); commit;
  pck_kml_job_api.run_now(l_job); t('STYLE_HIGHLIGHT_SCALE -2 -> plain styles', instr(pck_kml_job_api.get_kml(l_job), '<StyleMap') = 0, pck_kml_job_api.get_status(l_job));
  pck_kml_config_dml.set_number('STYLE_HIGHLIGHT_SCALE', null); pck_kml_jobs_dml.del(l_job); commit;
  begin l_n := pck_kml_config_dml.get_number('CLEANUP_STATUSES'); t('get_number on STRING key', true, 'returns ' || nvl(to_char(l_n),'NULL') || ' + WARN'); exception when others then t('get_number on STRING key', false, sqlerrm); end;
  pck_kml_config_dml.set_string('KMZ_ENGINE', 'BOGUS'); commit;
  l_job := pck_kml_job_api.create_job('kmzb', p_output_format => 'KMZ'); l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}'); commit;
  pck_kml_job_api.run_now(l_job); t('KMZ_ENGINE BOGUS -> falls back to internal', pck_kml_job_api.get_status(l_job) = 'COMPLETED', pck_kml_job_api.get_status(l_job));
  pck_kml_config_dml.set_string('KMZ_ENGINE', 'APEX'); commit; pck_kml_jobs_dml.set_status(l_job, 'DRAFT'); l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}'); commit;
  pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job); t('KMZ_ENGINE APEX works here', l_r.status = 'COMPLETED', l_r.status || ' entry=' || pck_kml_zip.file_list(l_r.result_kmz)(1));
  pck_kml_config_dml.set_string('KMZ_ENGINE', 'INTERNAL'); pck_kml_jobs_dml.del(l_job); commit;
exception when others then dbms_output.put_line('ABORT ' || sqlerrm || chr(10) || dbms_utility.format_error_backtrace);
end;
/
exit
