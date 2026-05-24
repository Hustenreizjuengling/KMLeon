--------------------------------------------------------------------------------
-- KMLeon demo data  (run in the schema that owns the KMLeon objects)
--------------------------------------------------------------------------------
-- Creates a few jobs via PCK_KML_JOB_API and runs them synchronously, so the
-- APEX "Jobs" report shows data immediately. Pure KMLeon API -- no APEX needed.
--   sqlplus kmleon/****@db @demo_data.sql
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job number;
  l_n   number;
begin
  ----------------------------------------------------------------- 1) ASSETS + GeoJSON, KML
  l_job := pck_kml_job_api.create_job(
             p_document_name => 'Demo: cities (GeoJSON)',
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
             p_document_name => 'Demo: query stream (SDO)',
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
             p_document_name => 'Demo: area (KMZ)',
             p_output_format => 'KMZ');
  l_n := pck_kml_job_api.add_features_geojson(l_job, q'~
    {"type":"Feature",
     "geometry":{"type":"Polygon","coordinates":[[[13.3,52.4],[13.5,52.4],[13.5,52.6],[13.3,52.6],[13.3,52.4]]]},
     "properties":{"NAME":"Berlin area","POLY_COLOR":"7f0000ff","POLY_FILL":"Y"}}~');
  commit;
  pck_kml_job_api.run_now(l_job);
  dbms_output.put_line('Job ' || l_job || ': ' || pck_kml_job_api.get_status(l_job));

  dbms_output.put_line('--- demo data ready; refresh the APEX Jobs report ---');
end;
/
