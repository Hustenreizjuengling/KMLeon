--------------------------------------------------------------------------------
-- KMLeon :: smoke test (QUERY / STREAM source)
--------------------------------------------------------------------------------
-- Creates a QUERY job whose SELECT is executed and streamed to KML at run time
-- (no assets are persisted). Demonstrates the alias contract: GEOMETRY drives the
-- shape, NAME/FOLDER_NAME/LINE_COLOR map to known roles, and COUNTRY (unknown) is
-- emitted automatically as <ExtendedData>. A bind (:region) is passed via JSON.
-- Run after install.sql. Requires SDO_UTIL. Uses KML output (no APEX_ZIP needed).
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set lines 200

declare
  l_job number;
  l_kml clob;
  l_query clob :=
    q'[
      select sdo_geometry(2001, 4326, sdo_point_type(13.405, 52.520, null), null, null) as geometry,
             'Berlin'    as name,
             'Cities'    as folder_name,
             :region     as country,
             pck_kml_engine.rgba_to_kml('FFFFFF') as label_color
        from dual
      union all
      select sdo_geometry(2001, 4326, sdo_point_type(8.682, 50.110, null), null, null),
             'Frankfurt', 'Cities', :region, pck_kml_engine.rgba_to_kml('FFFFFF')
        from dual
      order by name
    ]';
begin
  l_job := pck_kml_job_api.create_job_from_query(
             p_document_name => 'KMLeon query smoke test',
             p_source_query  => l_query,
             p_source_binds  => '{"region":"DE"}',
             p_output_format => 'KML',
             p_user_tab      => 'DEMO_USERS',
             p_user_id       => '42');
  commit;

  pck_kml_job_api.run_now(l_job);

  dbms_output.put_line('status      : ' || pck_kml_job_api.get_status(l_job));
  l_kml := pck_kml_job_api.get_kml(l_job);
  dbms_output.put_line('kml length  : ' || nvl(dbms_lob.getlength(l_kml), 0));
  dbms_output.put_line('--------------------------------------------------');
  dbms_output.put_line(dbms_lob.substr(l_kml, 3900, 1));
end;
/
