--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_JOB_API  (convenience API for consuming applications)
--------------------------------------------------------------------------------
-- Thin, optional wrapper over the DML packages and the engine. Applications may
-- equally call the *_DML packages directly. create_job/add_asset do NOT commit
-- (so a job + its assets can be built in one transaction); submit/run/cancel/
-- purge commit.
--
-- Typical usage:
--   l_job := pck_kml_job_api.create_job('Routes', p_output_format => 'KMZ');
--   pck_kml_job_api.add_asset(l_job, p_geometry_geojson =>
--       '{"type":"Point","coordinates":[13.405,52.52]}', p_name => 'Berlin');
--   commit;
--   pck_kml_job_api.submit_job(l_job);   -- dispatcher runs it; or run_now(l_job)
--------------------------------------------------------------------------------

create or replace package pck_kml_job_api
  authid definer
as
  c_pkg constant varchar2(30) := 'PCK_KML_JOB_API';

  function create_job(
    p_document_name   in varchar2,
    p_description     in varchar2 default null,
    p_output_format   in varchar2 default 'KMZ',
    p_output_filename in varchar2 default null,
    p_priority        in number   default 100,
    p_user_tab        in varchar2 default null,
    p_user_id         in varchar2 default null,
    p_notify_email    in varchar2 default null
  ) return number;

  -- Create a self-contained QUERY job in DRAFT status. The SELECT is executed at
  -- run time and streamed to KML; its column aliases drive the output:
  --   GEOMETRY (SDO_GEOMETRY) | GEOMETRY_GEOJSON | GEOMETRY_KML  (one of these)
  --   NAME, DESCRIPTION, FOLDER_NAME, VISIBILITY,
  --   ICON_HREF, ICON_SCALE, LABEL_COLOR, LABEL_SCALE,
  --   LINE_COLOR, LINE_WIDTH, POLY_COLOR, POLY_FILL, POLY_OUTLINE, EXTENDED_DATA
  -- Any other column becomes an <ExtendedData> property (alias = name).
  -- ORDER BY the folder column if you want <Folder> grouping. Pass parameters via
  -- p_source_binds (JSON, e.g. '{"region":"DE"}') referenced as :region in the SQL.
  function create_job_from_query(
    p_document_name   in varchar2,
    p_source_query    in clob,
    p_source_binds    in clob     default null,
    p_source_mode     in varchar2 default 'STREAM',   -- STREAM | MATERIALIZE
    p_description     in varchar2 default null,
    p_output_format   in varchar2 default 'KMZ',
    p_output_filename in varchar2 default null,
    p_priority        in number   default 100,
    p_user_tab        in varchar2 default null,
    p_user_id         in varchar2 default null,
    p_notify_email    in varchar2 default null
  ) return number;

  -- Bulk-add features to a job from GeoJSON (FeatureCollection / Feature / bare
  -- geometry). Mirrors the QUERY alias contract; returns the feature count. No commit.
  function add_features_geojson(p_job_id in number, p_feature_collection in clob) return number;

  -- Supply EXACTLY ONE of p_geometry_sdo / p_geometry_geojson.
  function add_asset(
    p_job_id           in number,
    p_geometry_sdo     in sdo_geometry default null,
    p_geometry_geojson in clob         default null,
    p_name             in varchar2 default null,
    p_description      in clob     default null,
    p_extended_data    in clob     default null,
    p_folder_name      in varchar2 default null,
    p_display_order    in number   default 0,
    p_altitude_mode    in varchar2 default null,
    p_extrude          in varchar2 default 'N',
    p_tessellate       in varchar2 default 'N',
    p_icon_href        in varchar2 default null,
    p_icon_scale       in number   default null,
    p_label_color      in varchar2 default null,
    p_label_scale      in number   default null,
    p_line_color       in varchar2 default null,
    p_line_width       in number   default null,
    p_poly_color       in varchar2 default null,
    p_poly_fill        in varchar2 default null,
    p_poly_outline     in varchar2 default null,
    p_visibility       in varchar2 default 'Y'
  ) return number;

  -- DRAFT -> PENDING; commits. With p_async => true it ALSO launches a one-shot
  -- background job (run_async) so the job runs immediately without waiting for the
  -- KMLEON_DISPATCHER cycle (which is disabled by default).
  procedure submit_job(p_job_id in number, p_async in boolean default false);

  -- Run a job immediately in its OWN one-shot DBMS_SCHEDULER job (non-blocking,
  -- runs in a background session, auto-drops when done). The job must be persisted
  -- (committed) first; create_job + commit, or submit_job, satisfy that. Needs the
  -- CREATE JOB privilege. Use run_now instead to run synchronously in this session.
  procedure run_async(p_job_id in number);

  procedure run_now(p_job_id in number);      -- run synchronously; commits
  procedure cancel_job(p_job_id in number);   -- DRAFT/PENDING -> CANCELLED; commits

  function get_status(p_job_id in number) return varchar2;
  function get_kml(p_job_id in number)    return clob;
  function get_kmz(p_job_id in number)    return blob;

  procedure purge_jobs(p_older_than_days in number default 30);  -- commits
end pck_kml_job_api;
/

create or replace package body pck_kml_job_api
as

  function create_job(
    p_document_name   in varchar2,
    p_description     in varchar2 default null,
    p_output_format   in varchar2 default 'KMZ',
    p_output_filename in varchar2 default null,
    p_priority        in number   default 100,
    p_user_tab        in varchar2 default null,
    p_user_id         in varchar2 default null,
    p_notify_email    in varchar2 default null
  ) return number
  is
  begin
    return pck_kml_jobs_dml.ins(
             p_document_name   => p_document_name,
             p_description     => p_description,
             p_output_format   => p_output_format,
             p_output_filename => p_output_filename,
             p_priority        => p_priority,
             p_user_tab        => p_user_tab,
             p_user_id         => p_user_id,
             p_notify_email    => p_notify_email);
  end create_job;


  function create_job_from_query(
    p_document_name   in varchar2,
    p_source_query    in clob,
    p_source_binds    in clob     default null,
    p_source_mode     in varchar2 default 'STREAM',
    p_description     in varchar2 default null,
    p_output_format   in varchar2 default 'KMZ',
    p_output_filename in varchar2 default null,
    p_priority        in number   default 100,
    p_user_tab        in varchar2 default null,
    p_user_id         in varchar2 default null,
    p_notify_email    in varchar2 default null
  ) return number
  is
  begin
    return pck_kml_jobs_dml.ins(
             p_document_name   => p_document_name,
             p_description     => p_description,
             p_output_format   => p_output_format,
             p_output_filename => p_output_filename,
             p_priority        => p_priority,
             p_user_tab        => p_user_tab,
             p_user_id         => p_user_id,
             p_notify_email    => p_notify_email,
             p_source_type     => 'QUERY',
             p_source_mode     => p_source_mode,
             p_source_query    => p_source_query,
             p_source_binds    => p_source_binds);
  end create_job_from_query;


  function add_features_geojson(p_job_id in number, p_feature_collection in clob) return number
  is
  begin
    return pck_kml_job_assets_dml.add_features_geojson(p_job_id, p_feature_collection);
  end add_features_geojson;


  function add_asset(
    p_job_id           in number,
    p_geometry_sdo     in sdo_geometry default null,
    p_geometry_geojson in clob         default null,
    p_name             in varchar2 default null,
    p_description      in clob     default null,
    p_extended_data    in clob     default null,
    p_folder_name      in varchar2 default null,
    p_display_order    in number   default 0,
    p_altitude_mode    in varchar2 default null,
    p_extrude          in varchar2 default 'N',
    p_tessellate       in varchar2 default 'N',
    p_icon_href        in varchar2 default null,
    p_icon_scale       in number   default null,
    p_label_color      in varchar2 default null,
    p_label_scale      in number   default null,
    p_line_color       in varchar2 default null,
    p_line_width       in number   default null,
    p_poly_color       in varchar2 default null,
    p_poly_fill        in varchar2 default null,
    p_poly_outline     in varchar2 default null,
    p_visibility       in varchar2 default 'Y'
  ) return number
  is
  begin
    return pck_kml_job_assets_dml.ins(
             p_job_id           => p_job_id,
             p_geometry_sdo     => p_geometry_sdo,
             p_geometry_geojson => p_geometry_geojson,
             p_name             => p_name,
             p_description      => p_description,
             p_extended_data    => p_extended_data,
             p_folder_name      => p_folder_name,
             p_display_order    => p_display_order,
             p_altitude_mode    => p_altitude_mode,
             p_extrude          => p_extrude,
             p_tessellate       => p_tessellate,
             p_icon_href        => p_icon_href,
             p_icon_scale       => p_icon_scale,
             p_label_color      => p_label_color,
             p_label_scale      => p_label_scale,
             p_line_color       => p_line_color,
             p_line_width       => p_line_width,
             p_poly_color       => p_poly_color,
             p_poly_fill        => p_poly_fill,
             p_poly_outline     => p_poly_outline,
             p_visibility       => p_visibility);
  end add_asset;


  procedure run_async(p_job_id in number) is
    l_status kml_jobs.status%type;
    l_name   varchar2(128);
  begin
    l_status := get_status(p_job_id);   -- existence check (raises -20813 if not found)
    l_name   := dbms_scheduler.generate_job_name('KMLEON_RUN_');
    dbms_scheduler.create_job(           -- create_job commits, so the row is visible to the bg session
      job_name   => l_name,
      job_type   => 'PLSQL_BLOCK',
      job_action => 'begin pck_kml_engine.run_job(' || p_job_id || '); end;',
      start_date => systimestamp,
      enabled    => true,
      auto_drop  => true,
      comments   => 'KMLeon: one-shot async run of job ' || p_job_id
    );
    pck_kml_log.info(c_pkg, 'run_async', 'launched ' || l_name || ' (from status ' || l_status || ')', p_job_id);
  end run_async;


  procedure submit_job(p_job_id in number, p_async in boolean default false) is
    l_status kml_jobs.status%type;
  begin
    l_status := get_status(p_job_id);
    if l_status != 'DRAFT' then
      raise_application_error(-20810,
        'Job ' || p_job_id || ' cannot be submitted (status ' || l_status || ', expected DRAFT).');
    end if;
    pck_kml_jobs_dml.set_status(p_job_id, 'PENDING');
    commit;
    if p_async then
      run_async(p_job_id);   -- run now in its own background job (don't wait for the dispatcher)
    end if;
  end submit_job;


  procedure run_now(p_job_id in number) is
  begin
    pck_kml_engine.run_job(p_job_id);   -- commits internally
  end run_now;


  procedure cancel_job(p_job_id in number) is
    l_job kml_jobs%rowtype;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);   -- raises -20813 if the job does not exist
    if pck_kml_jobs_dml.cancel(p_job_id) = 0 then
      raise_application_error(-20811,
        'Job ' || p_job_id || ' cannot be cancelled (status ' || l_job.status || '; only DRAFT/PENDING).');
    end if;
    commit;
  end cancel_job;


  function get_status(p_job_id in number) return varchar2 is
    l_job kml_jobs%rowtype;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);
    return l_job.status;
  end get_status;


  function get_kml(p_job_id in number) return clob is
    l_job kml_jobs%rowtype;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);
    return l_job.result_kml;
  end get_kml;


  function get_kmz(p_job_id in number) return blob is
    l_job kml_jobs%rowtype;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);
    return l_job.result_kmz;
  end get_kmz;


  procedure purge_jobs(p_older_than_days in number default 30) is
  begin
    pck_kml_jobs_dml.purge_finished(p_older_than_days);
    commit;
  end purge_jobs;

end pck_kml_job_api;
/
