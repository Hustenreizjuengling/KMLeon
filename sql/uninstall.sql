--------------------------------------------------------------------------------
-- KMLeon :: uninstall (drops all KMLeon objects)
--------------------------------------------------------------------------------
set serveroutput on
whenever sqlerror continue

begin
  begin
    dbms_scheduler.drop_job('KMLEON_DISPATCHER', force => true);
  exception when others then null;
  end;
  begin
    dbms_scheduler.drop_job('KMLEON_MAINTENANCE', force => true);
  exception when others then null;
  end;
end;
/

drop package pck_kml_maintenance;
drop package pck_kml_job_api;
drop package pck_kml_engine;
drop package pck_kml_notify;
drop package pck_kml_kmz;
drop package pck_kml_job_assets_dml;
drop package pck_kml_jobs_dml;
drop package pck_kml_config_dml;
drop package pck_kml_log;

drop table kml_job_assets purge;
drop table kml_jobs        purge;
drop table kml_config      purge;
drop table kml_log         purge;

prompt KMLeon removed.
