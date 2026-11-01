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
  -- one-shot async run jobs (PCK_KML_JOB_API.run_async); usually auto-dropped,
  -- but drop any that are still pending/running so nothing is left orphaned.
  for j in (select job_name from user_scheduler_jobs
             where job_name like 'KMLEON\_RUN\_%' escape '\') loop
    begin
      dbms_scheduler.drop_job(j.job_name, force => true);
    exception when others then null;
    end;
  end loop;
end;
/

drop package pck_kml_maintenance;
drop package pck_kml_job_api;
drop package pck_kml_engine;
drop package pck_kml_geom;
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

-- The optional ORDS module and the APEX toolkit app are NOT dropped here (they
-- live outside this schema's object namespace). If installed, remove them via:
--   begin ords.delete_module(p_module_name => 'kmleon.v1'); commit; end;  -- SQL Workshop
--   (App Builder: delete the "KMLeon Toolkit" application)
prompt KMLeon removed. (ORDS module / APEX app, if installed, must be removed separately - see header.)
