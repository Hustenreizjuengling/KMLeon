--------------------------------------------------------------------------------
-- KMLeon :: DBMS_SCHEDULER maintenance (cleanup) job
--------------------------------------------------------------------------------
-- Creates the KMLEON_MAINTENANCE job from the current KML_CONFIG settings by
-- delegating to PCK_KML_MAINTENANCE.apply_schedule. The job runs
-- PCK_KML_MAINTENANCE.cleanup on the configured interval and deletes old
-- terminal-status jobs (+their assets) per the CLEANUP_* settings.
--
-- Run this AFTER install.sql, as the schema that owns the KMLeon objects.
-- Re-run it any time you change CLEANUP_ENABLED or CLEANUP_INTERVAL.
--------------------------------------------------------------------------------
-- Configure first (examples), then (re)apply the schedule:
--   exec pck_kml_config_dml.set_boolean('CLEANUP_ENABLED', true);
--   exec pck_kml_config_dml.set_string ('CLEANUP_INTERVAL', 'FREQ=DAILY;BYHOUR=3');
--   exec pck_kml_config_dml.set_number ('CLEANUP_RETENTION_DAYS', 30);
--   exec pck_kml_config_dml.set_string ('CLEANUP_STATUSES', 'COMPLETED,CANCELLED');
--   commit;
--------------------------------------------------------------------------------

begin
  pck_kml_maintenance.apply_schedule;
end;
/

-- Handy operational commands (run individually as needed):
--   exec pck_kml_maintenance.apply_schedule;                    -- re-read config & (re)create
--   declare n pls_integer; begin n := pck_kml_maintenance.run_cleanup(p_force => true); end;  -- run once, now
--   exec dbms_scheduler.run_job('KMLEON_MAINTENANCE');          -- run via scheduler, now
--   exec dbms_scheduler.disable('KMLEON_MAINTENANCE');
--   exec dbms_scheduler.drop_job('KMLEON_MAINTENANCE', force => true);
--
-- Inspect status / history:
--   select job_name, enabled, state, next_run_date from user_scheduler_jobs;
--   select log_date, status, additional_info
--     from user_scheduler_job_run_details
--    where job_name = 'KMLEON_MAINTENANCE' order by log_date desc;
