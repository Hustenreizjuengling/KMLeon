--------------------------------------------------------------------------------
-- KMLeon :: DBMS_SCHEDULER dispatcher
--------------------------------------------------------------------------------
-- Creates a repeating job that drains the PENDING queue by calling
-- KML_ENGINE.process_pending. Adjust the interval / batch size to taste.
--
-- It is created DISABLED by default: the recommended path is to run jobs in
-- their own one-shot background job via PCK_KML_JOB_API.run_async / submit_job(
-- p_async => true). Enable this dispatcher only if you prefer a polled PENDING
-- queue:  exec dbms_scheduler.enable('KMLEON_DISPATCHER');
--
-- Run this AFTER install.sql, as the schema that owns the KMLeon objects.
--------------------------------------------------------------------------------

declare
  c_job_name constant varchar2(30) := 'KMLEON_DISPATCHER';
begin
  -- drop a pre-existing job so this script is re-runnable
  begin
    dbms_scheduler.drop_job(job_name => c_job_name, force => true);
  exception
    when others then
      if sqlcode != -27475 then  -- ORA-27475: "unknown job"
        raise;
      end if;
  end;

  dbms_scheduler.create_job(
    job_name        => c_job_name,
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'begin pck_kml_engine.process_pending(p_limit => 50); end;',
    start_date      => systimestamp,
    repeat_interval => 'FREQ=MINUTELY; INTERVAL=1',
    enabled         => false,   -- DISABLED by default; enable explicitly (see header / below)
    auto_drop       => false,
    comments        => 'KMLeon: process PENDING KML/KMZ jobs'
  );
end;
/

-- Handy operational commands (run individually as needed):
--   exec dbms_scheduler.disable('KMLEON_DISPATCHER');
--   exec dbms_scheduler.enable ('KMLEON_DISPATCHER');
--   exec dbms_scheduler.run_job('KMLEON_DISPATCHER');           -- run once, now
--   exec dbms_scheduler.drop_job('KMLEON_DISPATCHER', force => true);
--
-- Inspect status / history:
--   select job_name, enabled, state, next_run_date from user_scheduler_jobs;
--   select log_date, status, additional_info
--     from user_scheduler_job_run_details
--    where job_name = 'KMLEON_DISPATCHER' order by log_date desc;
