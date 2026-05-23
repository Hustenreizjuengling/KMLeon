--------------------------------------------------------------------------------
-- KMLeon :: smoke test (GeoJSON ingestion + MATERIALIZE)
--------------------------------------------------------------------------------
-- Part 1: external-style ASSETS job fed by a GeoJSON FeatureCollection
--         (reserved properties -> columns, others -> ExtendedData).
-- Part 2: a QUERY job in MATERIALIZE mode (rows are written to KML_JOB_ASSETS,
--         then rendered). Run after install.sql. KML output (no APEX_ZIP needed).
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set lines 200

declare
  l_job number;
  l_n   number;
  l_kml clob;
begin
  ----------------------------------------------------------------- Part 1
  l_job := pck_kml_job_api.create_job(
             p_document_name => 'GeoJSON upload test',
             p_output_format => 'KML');

  l_n := pck_kml_job_api.add_features_geojson(l_job, q'[
    {
      "type": "FeatureCollection",
      "features": [
        { "type": "Feature",
          "geometry": { "type": "Point", "coordinates": [13.405, 52.520] },
          "properties": { "NAME": "Berlin", "FOLDER_NAME": "Cities",
                          "LABEL_COLOR": "ffffffff", "country": "DE", "rank": 1 } },
        { "type": "Feature",
          "geometry": { "type": "LineString", "coordinates": [[13.40,52.52],[8.68,50.11]] },
          "properties": { "NAME": "Route", "FOLDER_NAME": "Routes",
                          "LINE_COLOR": "ff0000ff", "LINE_WIDTH": 3 } }
      ]
    }]');
  commit;

  pck_kml_job_api.run_now(l_job);
  l_kml := pck_kml_job_api.get_kml(l_job);
  dbms_output.put_line('Part1 status : ' || pck_kml_job_api.get_status(l_job)
                       || '  features=' || l_n
                       || '  kml_len=' || nvl(dbms_lob.getlength(l_kml), 0));

  ----------------------------------------------------------------- Part 2
  l_job := pck_kml_job_api.create_job_from_query(
             p_document_name => 'Materialized query test',
             p_output_format => 'KML',
             p_source_mode   => 'MATERIALIZE',
             p_source_query  => q'[
                 select sdo_geometry(2001, 4326, sdo_point_type(11.58, 48.14, null), null, null) as geometry,
                        'Munich' as name, 'Cities' as folder_name, 'DE' as country
                   from dual ]');
  commit;

  pck_kml_job_api.run_now(l_job);
  dbms_output.put_line('Part2 status : ' || pck_kml_job_api.get_status(l_job));
  -- assets were persisted by MATERIALIZE:
  for r in (select count(*) c from kml_job_assets where job_id = l_job) loop
    dbms_output.put_line('Part2 materialized assets = ' || r.c);
  end loop;
end;
/
