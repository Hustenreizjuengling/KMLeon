--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_MAINTENANCE  (config-driven cleanup + its scheduler job)
--------------------------------------------------------------------------------
-- Reads the CLEANUP_* settings from KML_CONFIG and purges old terminal-status
-- jobs (+their assets, via the jobs DML package). apply_schedule (re)creates the
-- KMLEON_MAINTENANCE DBMS_SCHEDULER job from the configured switch + interval.
-- Depends on PCK_KML_CONFIG_DML, PCK_KML_JOBS_DML, PCK_KML_LOG.
--------------------------------------------------------------------------------

create or replace package pck_kml_maintenance
  authid definer
as
  c_pkg      constant varchar2(30) := 'PCK_KML_MAINTENANCE';
  c_job_name constant varchar2(30) := 'KMLEON_MAINTENANCE';

  -- Run the cleanup once. Honours CLEANUP_ENABLED unless p_force is true
  -- (the "Run cleanup now" action passes p_force => true). Returns rows deleted.
  function run_cleanup(p_force in boolean default false) return pls_integer;

  -- Procedure form for the scheduler job (respects CLEANUP_ENABLED).
  procedure cleanup;

  -- (Re)create / drop the KMLEON_MAINTENANCE job from the current config.
  procedure apply_schedule;

  -- A job whose session died mid-run (killed session, instance restart, ...)
  -- stays RUNNING forever and the claim guard refuses to re-run it. Mark every
  -- RUNNING job older than p_minutes (default: setting STALE_RUNNING_MINUTES,
  -- 120) as FAILED with a clear message so it can be re-run / cleaned up.
  -- Called by run_cleanup; also callable on its own. Returns rows recovered.
  -- Does NOT commit when called directly (run_cleanup commits).
  function recover_stale_jobs(p_minutes in number default null) return pls_integer;
end pck_kml_maintenance;
/

create or replace package body pck_kml_maintenance
as

  function recover_stale_jobs(p_minutes in number default null) return pls_integer is
    l_minutes number := nvl(p_minutes, pck_kml_config_dml.get_number('STALE_RUNNING_MINUTES', 120));
    l_n       pls_integer := 0;
  begin
    if l_minutes is null or l_minutes <= 0 then
      return 0;   -- disabled
    end if;
    for r in (select job_id, started_at
                from kml_jobs
               where status = 'RUNNING'
                 and nvl(started_at, updated_at) < systimestamp - numtodsinterval(l_minutes, 'MINUTE')
               order by job_id) loop
      pck_kml_jobs_dml.set_failed(r.job_id,
        'Recovered by maintenance: job was RUNNING since ' || to_char(r.started_at, 'YYYY-MM-DD HH24:MI:SS')
        || ' (> ' || l_minutes || ' min) -- its session most likely died. Re-run the job.');
      pck_kml_log.warn(c_pkg, 'recover_stale_jobs', 'stale RUNNING job marked FAILED', r.job_id);
      l_n := l_n + 1;
    end loop;
    return l_n;
  end recover_stale_jobs;


  function run_cleanup(p_force in boolean default false) return pls_integer is
    l_enabled   boolean      := pck_kml_config_dml.get_boolean('CLEANUP_ENABLED', false);
    l_statuses  varchar2(200) := pck_kml_config_dml.get_string('CLEANUP_STATUSES', 'COMPLETED,CANCELLED');
    l_retention number       := pck_kml_config_dml.get_number('CLEANUP_RETENTION_DAYS', 30);
    l_log_ret   number       := pck_kml_config_dml.get_number('CLEANUP_LOG_RETENTION_DAYS', 90);
    l_deleted   pls_integer;
    l_log_del   pls_integer;
    l_stale     pls_integer;
  begin
    if not l_enabled and not p_force then
      pck_kml_log.info(c_pkg, 'run_cleanup', 'skipped (CLEANUP_ENABLED = N)');
      return 0;
    end if;

    if l_retention is null or l_retention < 0 then
      pck_kml_log.warn(c_pkg, 'run_cleanup', 'CLEANUP_RETENTION_DAYS=' || l_retention || ' is invalid; using 0 (delete finished jobs regardless of age)');
      l_retention := 0;
    end if;
    l_stale   := recover_stale_jobs;
    l_deleted := pck_kml_jobs_dml.purge(l_statuses, l_retention);
    l_log_del := pck_kml_log.purge(l_log_ret);   -- housekeeping for KML_LOG (0 = disabled)

    -- best-effort metrics: a metric write must not roll back the purge
    begin
      pck_kml_config_dml.touch_metric('METRIC_LAST_CLEANUP_AT');
      pck_kml_config_dml.set_number('METRIC_LAST_CLEANUP_DELETED', l_deleted, 'METRIC');
    exception when others then
      pck_kml_log.warn(c_pkg, 'run_cleanup', 'metric update skipped: ' || sqlerrm);
    end;
    commit;

    pck_kml_log.info(c_pkg, 'run_cleanup',
      'done; stale_recovered=' || l_stale || ' jobs_deleted=' || l_deleted || ' log_deleted=' || l_log_del);
    return l_deleted;
  exception
    when others then
      rollback;
      pck_kml_log.error(c_pkg, 'run_cleanup',
        sqlerrm || chr(10) || dbms_utility.format_error_backtrace);
      raise;
  end run_cleanup;


  procedure cleanup is
    l_void pls_integer;
  begin
    l_void := run_cleanup(p_force => false);
  end cleanup;


  procedure apply_schedule is
    l_enabled  boolean       := pck_kml_config_dml.get_boolean('CLEANUP_ENABLED', false);
    l_interval varchar2(400) := pck_kml_config_dml.get_string('CLEANUP_INTERVAL', 'FREQ=DAILY;BYHOUR=3');
    l_next     timestamp with time zone;
  begin
    -- validate the calendar string FIRST: a typo must not drop the existing job
    -- and leave the installation without a schedule
    if l_enabled then
      begin
        dbms_scheduler.evaluate_calendar_string(l_interval, null, null, l_next);
      exception
        when others then
          raise_application_error(-20841,
            'CLEANUP_INTERVAL "' || l_interval || '" is not a valid DBMS_SCHEDULER calendar string: ' || sqlerrm);
      end;
    end if;
    -- drop any existing job so this is re-runnable
    begin
      dbms_scheduler.drop_job(job_name => c_job_name, force => true);
    exception
      when others then
        if sqlcode != -27475 then  -- ORA-27475: "unknown job"
          raise;
        end if;
    end;

    if l_enabled then
      dbms_scheduler.create_job(
        job_name        => c_job_name,
        job_type        => 'PLSQL_BLOCK',
        job_action      => 'begin pck_kml_maintenance.cleanup; end;',
        start_date      => systimestamp,
        repeat_interval => l_interval,
        enabled         => true,
        auto_drop       => false,
        comments        => 'KMLeon: scheduled cleanup of old terminal-status jobs'
      );
      pck_kml_log.info(c_pkg, 'apply_schedule', 'job enabled; interval=' || l_interval);
    else
      pck_kml_log.info(c_pkg, 'apply_schedule', 'job disabled (CLEANUP_ENABLED = N)');
    end if;
  end apply_schedule;

end pck_kml_maintenance;
/
