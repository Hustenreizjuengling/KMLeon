--------------------------------------------------------------------------------
-- KMLeon :: smoke test - large ExtendedData (> 32 KB) must not be dropped
--------------------------------------------------------------------------------
-- A feature with many large properties used to lose its whole <ExtendedData>
-- block silently (varchar2(32767) overflow caught by the best-effort handler).
-- Asserts every property survives in the rendered KML, for the ASSETS path
-- (extended_data JSON) and the QUERY path (EXTENDED_DATA column + extra columns).
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job  number;
  l_a    number;
  l_kml  clob;
  l_json clob;
  l_val  varchar2(300) := rpad('x', 300, 'x');
  c_keys constant pls_integer := 200;          -- 200 x ~320 bytes = ~64 KB
begin
  dbms_lob.createtemporary(l_json, true);
  dbms_lob.writeappend(l_json, 1, '{');
  for i in 1 .. c_keys loop
    dbms_lob.writeappend(l_json, length('"k' || i || '":"' || l_val || '"'), '"k' || i || '":"' || l_val || '"');
    if i < c_keys then dbms_lob.writeappend(l_json, 1, ','); end if;
  end loop;
  dbms_lob.writeappend(l_json, 1, '}');

  --- ASSETS path --------------------------------------------------------------
  l_job := pck_kml_job_api.create_job(p_document_name => 'ExtendedData smoke', p_output_format => 'KML');
  l_a := pck_kml_job_api.add_asset(
           p_job_id           => l_job,
           p_geometry_geojson => to_clob('{"type":"Point","coordinates":[13.405,52.52]}'),
           p_name             => 'Big balloon',
           p_extended_data    => l_json);
  commit;
  pck_kml_job_api.run_now(l_job);
  l_kml := pck_kml_job_api.get_kml(l_job);
  dbms_output.put_line('assets : ' || pck_kml_job_api.get_status(l_job) || ', kml ' || dbms_lob.getlength(l_kml) || ' chars');
  if pck_kml_job_api.get_status(l_job) != 'COMPLETED'
     or dbms_lob.instr(l_kml, '<Data name="k1">') = 0
     or dbms_lob.instr(l_kml, '<Data name="k' || c_keys || '">') = 0 then
    raise_application_error(-20999, 'extdata smoke FAILED (ASSETS): ExtendedData incomplete');
  end if;
  pck_kml_jobs_dml.del(l_job);
  commit;

  --- QUERY path (STREAM) ------------------------------------------------------
  l_job := pck_kml_job_api.create_job_from_query(
             p_document_name => 'ExtendedData smoke (query)',
             p_output_format => 'KML',
             p_source_query  => q'[
               select sdo_geometry(2001, 4326, sdo_point_type(13.405, 52.52, null), null, null) as geometry,
                      'Big balloon' as name,
                      (select json_objectagg('k' || level value rpad('x', 300, 'x') returning clob)
                         from dual connect by level <= :n) as extended_data,
                      'extra' as extra_prop
                 from dual ]',
             p_source_binds  => '{"n":' || c_keys || '}');
  commit;
  pck_kml_job_api.run_now(l_job);
  l_kml := pck_kml_job_api.get_kml(l_job);
  dbms_output.put_line('query  : ' || pck_kml_job_api.get_status(l_job) || ', kml ' || dbms_lob.getlength(l_kml) || ' chars');
  if pck_kml_job_api.get_status(l_job) != 'COMPLETED'
     or dbms_lob.instr(l_kml, '<Data name="k' || c_keys || '">') = 0
     or dbms_lob.instr(l_kml, '<Data name="EXTRA_PROP"><value>extra</value>') = 0 then
    raise_application_error(-20999, 'extdata smoke FAILED (QUERY): ExtendedData incomplete');
  end if;
  pck_kml_jobs_dml.del(l_job);
  commit;
  dbms_lob.freetemporary(l_json);
  dbms_output.put_line('extdata smoke test OK (jobs cleaned up)');
end;
/
