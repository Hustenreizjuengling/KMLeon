--------------------------------------------------------------------------------
-- KMLeon Toolkit :: one-shot setup
--------------------------------------------------------------------------------
-- Run as the schema that owns the KMLeon objects:
--   sqlplus kmleon/****@db @setup.sql
--   -- or in SQLcl: sql kmleon/****@db @setup.sql
--
-- This installs the toolkit's helper package (PCK_KMLEON_TOOLS) used by the
-- APEX pages, then seeds a few sample jobs via PCK_KML_JOB_API so the reports
-- have data immediately. Re-runnable: the package uses CREATE OR REPLACE; the
-- sample jobs accumulate (delete them by hand if you don't want extras).
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set echo off
whenever sqlerror continue

prompt -- package PCK_KMLEON_TOOLS (lives alongside the core KMLeon packages)
@@../sql/packages/pck_kmleon_tools.sql
show errors

prompt -- sample jobs
declare
  l_job number;
  l_n   number;
begin
  ----------------------------------------------------------------- 1) ASSETS + GeoJSON, KML
  l_job := pck_kml_job_api.create_job(
             p_document_name => 'Sample: cities (GeoJSON)',
             p_output_format => 'KML',
             p_notify_email  => 'demo@example.com');
  l_n := pck_kml_job_api.add_features_geojson(l_job, q'~
    {"type":"FeatureCollection","features":[
      {"type":"Feature",
       "geometry":{"type":"Point","coordinates":[13.405,52.52]},
       "properties":{"NAME":"Berlin","FOLDER_NAME":"Cities/Germany","country":"DE","rank":1}},
      {"type":"Feature",
       "geometry":{"type":"Point","coordinates":[11.58,48.14]},
       "properties":{"NAME":"Munich","FOLDER_NAME":"Cities/Germany","country":"DE","rank":2}}
    ]}~');
  commit;
  pck_kml_job_api.run_now(l_job);
  dbms_output.put_line('Job ' || l_job || ': ' || pck_kml_job_api.get_status(l_job) || ' (' || l_n || ' features)');

  ----------------------------------------------------------------- 2) QUERY / STREAM (SDO), KML
  l_job := pck_kml_job_api.create_job_from_query(
             p_document_name => 'Sample: query stream (SDO)',
             p_output_format => 'KML',
             p_source_query  => q'~
                 select sdo_geometry(2001, 4326, sdo_point_type(8.68, 50.11, null), null, null) as geometry,
                        'Frankfurt' as name,
                        'Cities'    as folder_name,
                        'DE'        as country
                   from dual ~');
  commit;
  pck_kml_job_api.run_now(l_job);
  dbms_output.put_line('Job ' || l_job || ': ' || pck_kml_job_api.get_status(l_job));

  ----------------------------------------------------------------- 3) ASSETS polygon, KMZ (needs APEX_ZIP)
  l_job := pck_kml_job_api.create_job(
             p_document_name => 'Sample: area (KMZ)',
             p_output_format => 'KMZ');
  l_n := pck_kml_job_api.add_features_geojson(l_job, q'~
    {"type":"Feature",
     "geometry":{"type":"Polygon","coordinates":[[[13.3,52.4],[13.5,52.4],[13.5,52.6],[13.3,52.6],[13.3,52.4]]]},
     "properties":{"NAME":"Berlin area","POLY_COLOR":"7f0000ff","POLY_FILL":"Y"}}~');
  commit;
  pck_kml_job_api.run_now(l_job);
  dbms_output.put_line('Job ' || l_job || ': ' || pck_kml_job_api.get_status(l_job));

  dbms_output.put_line('--- toolkit setup done; refresh the APEX Jobs report ---');
end;
/
