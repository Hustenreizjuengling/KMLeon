--------------------------------------------------------------------------------
-- KMLeon :: smoke test - hostile input (findings of the break-it campaign)
--------------------------------------------------------------------------------
-- * supplementary characters (emoji) keep the document well-formed UTF-8
-- * invalid colors / negative scales are rejected at insert (-20822/-20823) and
--   never emitted for QUERY rows; nested ExtendedData values become JSON text
-- * QUERY source: only SELECT/WITH is accepted (-20817), a query without a
--   geometry column fails clearly (-20818), a non-well-formed GEOMETRY_KML
--   passthrough is skipped, not emitted
-- * PCK_KML_GEOM: NULL ordinate (-20833) and corrupt elem_info (-20832) raise
-- * GeoJSON ingestion rejects non-GeoJSON objects / FeatureCollections without
--   an array (-20821) and skips features without a valid geometry
-- * maintenance recovers stale RUNNING jobs
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited

declare
  l_job number; l_a number; l_n number; l_kml clob; l_x xmltype; l_r kml_jobs%rowtype;
  l_cnt pls_integer := 0;
  procedure must(p_cond in boolean, p_what in varchar2) is
  begin
    l_cnt := l_cnt + 1;
    if not p_cond then raise_application_error(-20999, 'hostile smoke FAILED: ' || p_what); end if;
    dbms_output.put_line('OK   ' || p_what);
  end must;
  procedure expect_err(p_code in pls_integer, p_what in varchar2) is   -- call after a block that must have raised
  begin
    if sqlcode <> p_code then raise_application_error(-20999, 'hostile smoke FAILED: ' || p_what || ' raised ' || sqlcode || ' instead of ' || p_code); end if;
    l_cnt := l_cnt + 1; dbms_output.put_line('OK   ' || p_what);
  end expect_err;
  function qjob(p_sql varchar2) return kml_jobs%rowtype is
  begin
    l_job := pck_kml_job_api.create_job_from_query('hostile q', p_sql, p_output_format => 'KML'); commit;
    pck_kml_job_api.run_now(l_job); return pck_kml_jobs_dml.get(l_job);
  end qjob;
begin
  --- emoji / hostile text -------------------------------------------------------
  l_job := pck_kml_job_api.create_job('hostile 😀 <&> ]]>', p_output_format => 'KML', p_description => 'd <b>&</b> ]]>');
  l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}',
           p_name => 'N 😀 <tag> & "q" ]]>', p_folder_name => 'A<b>/B&C', p_description => to_clob('<p>x</p> ]]> </description>'),
           p_extended_data => '{"k<>&\"😀": "v ]]>", "arr": [1,2], "obj": {"a": null}, "b": true, "n": 1.5}');
  commit;
  pck_kml_job_api.run_now(l_job);
  l_kml := pck_kml_job_api.get_kml(l_job);
  must(pck_kml_job_api.get_status(l_job) = 'COMPLETED', 'hostile text job completes');
  l_x := xmltype(l_kml);
  must(l_x is not null, 'document with emoji + hostile text is well-formed XML');
  must(instr(l_kml, '<name>N 😀 &lt;tag&gt; &amp; &quot;q&quot; ]]&gt;</name>') > 0, 'name escaped, emoji intact');
  must(instr(l_kml, '<Data name="arr"><value>[1,2]</value></Data>') > 0 and instr(l_kml, '<Data name="b"><value>true</value></Data>') > 0, 'nested ExtendedData as JSON text, booleans as true/false');
  pck_kml_jobs_dml.del(l_job); commit;

  --- style validation --------------------------------------------------------------
  l_job := pck_kml_job_api.create_job('hostile style', p_output_format => 'KML'); commit;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_line_color => 'red');
        raise_application_error(-20999, 'hostile smoke FAILED: color "red" accepted');
  exception when others then expect_err(-20822, 'invalid color rejected at insert'); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_line_width => -1);
        raise_application_error(-20999, 'hostile smoke FAILED: negative width accepted');
  exception when others then expect_err(-20823, 'negative width rejected at insert'); end;
  pck_kml_jobs_dml.del(l_job); commit;
  l_r := qjob(q'[select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, 'red' as line_color, -3 as icon_scale, 'ff0000ff' as poly_color from dual]');
  l_kml := l_r.result_kml;
  must(l_r.status = 'COMPLETED' and instr(l_kml, 'red') = 0 and instr(l_kml, '-3') = 0 and instr(l_kml, '<color>ff0000ff</color>') > 0, 'QUERY rows: invalid color / negative scale dropped, valid color kept');
  pck_kml_jobs_dml.del(l_job);

  --- QUERY source contract ----------------------------------------------------------
  begin l_job := pck_kml_job_api.create_job_from_query('x', '/* c */ -- c' || chr(10) || 'create table pwned(x int)');
        raise_application_error(-20999, 'hostile smoke FAILED: DDL stored as source_query');
  exception when others then expect_err(-20817, 'non-SELECT source_query rejected'); end;
  begin l_job := pck_kml_job_api.create_job_from_query('x', 'begin null; end;');
        raise_application_error(-20999, 'hostile smoke FAILED: PL/SQL stored as source_query');
  exception when others then expect_err(-20817, 'PL/SQL block rejected as source_query'); end;
  l_r := qjob('with g as (select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry from dual) select * from g');
  must(l_r.status = 'COMPLETED' and l_r.asset_count = 1, 'WITH ... SELECT accepted');
  pck_kml_jobs_dml.del(l_job);
  l_r := qjob('select ''x'' as name from dual');
  must(l_r.status = 'FAILED' and l_r.error_message like '%ORA-20818%', 'query without geometry column fails with -20818');
  pck_kml_jobs_dml.del(l_job);
  l_r := qjob(q'[select '<Point><coordinates>1,2' as geometry_kml from dual union all select '<Point><coordinates>3,4</coordinates></Point>' from dual]');
  must(l_r.status = 'COMPLETED' and l_r.asset_count = 1 and instr(l_r.result_kml, '3,4') > 0, 'broken GEOMETRY_KML passthrough skipped, valid one kept');
  pck_kml_jobs_dml.del(l_job); commit;

  --- geometry guards ----------------------------------------------------------------
  begin l_kml := pck_kml_geom.to_kml(sdo_geometry(2001, 4326, sdo_point_type(1, null, null), null, null));
        raise_application_error(-20999, 'hostile smoke FAILED: NULL ordinate emitted');
  exception when others then expect_err(-20833, 'NULL ordinate raises -20833'); end;
  begin l_kml := pck_kml_geom.to_kml(sdo_geometry(2002, 4326, null, sdo_elem_info_array(1,2,1, 99,2,1), sdo_ordinate_array(1,2,3,4)));
        raise_application_error(-20999, 'hostile smoke FAILED: corrupt elem_info accepted');
  exception when others then expect_err(-20832, 'corrupt elem_info raises -20832'); end;
  l_job := pck_kml_job_api.create_job('hostile geom', p_output_format => 'KML');
  l_a := pck_kml_job_api.add_asset(l_job, p_geometry_sdo => sdo_geometry(2001, 4326, sdo_point_type(1, null, null), null, null), p_name => 'bad');
  l_a := pck_kml_job_api.add_asset(l_job, p_geometry_sdo => sdo_geometry(2001, 4326, sdo_point_type(1, 2, null), null, null), p_name => 'good');
  commit; pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job);
  must(l_r.status = 'COMPLETED' and l_r.asset_count = 1, 'asset with NULL ordinate skipped (WARN), job completes with the good one');
  pck_kml_jobs_dml.del(l_job); commit;

  --- GeoJSON ingestion ---------------------------------------------------------------
  l_job := pck_kml_job_api.create_job('hostile geojson', p_output_format => 'KML'); commit;
  begin l_n := pck_kml_job_api.add_features_geojson(l_job, '{"type":"Thing"}');
        raise_application_error(-20999, 'hostile smoke FAILED: non-GeoJSON accepted');
  exception when others then expect_err(-20821, 'non-GeoJSON object rejected'); end;
  begin l_n := pck_kml_job_api.add_features_geojson(l_job, '{"type":"FeatureCollection","features":{"a":1}}');
        raise_application_error(-20999, 'hostile smoke FAILED: features object accepted');
  exception when others then expect_err(-20821, 'FeatureCollection without array rejected'); end;
  l_n := pck_kml_job_api.add_features_geojson(l_job, '{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"NAME":"nogeom"}},{"type":"Feature","geometry":{"type":"Circle","coordinates":[1,2]},"properties":{}},{"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{"NAME":"ok","VISIBILITY":false}}]}');
  must(l_n = 1, 'features without valid geometry skipped, valid one added');
  pck_kml_jobs_dml.del(l_job); commit;

  --- stale RUNNING recovery ---------------------------------------------------------
  l_job := pck_kml_job_api.create_job('hostile stale', p_output_format => 'KML');
  pck_kml_jobs_dml.set_running(l_job);
  update kml_jobs set started_at = systimestamp - numtodsinterval(3, 'HOUR') where job_id = l_job;   -- test-only backdating
  commit;
  l_n := pck_kml_maintenance.recover_stale_jobs(p_minutes => 120);
  l_r := pck_kml_jobs_dml.get(l_job);
  must(l_n >= 1 and l_r.status = 'FAILED' and l_r.error_message like 'Recovered by maintenance%', 'stale RUNNING job recovered to FAILED');
  pck_kml_jobs_dml.set_running(l_job); commit;
  l_n := pck_kml_maintenance.recover_stale_jobs(p_minutes => 120);
  must(pck_kml_job_api.get_status(l_job) = 'RUNNING', 'fresh RUNNING job untouched');
  pck_kml_jobs_dml.del(l_job); commit;

  dbms_output.put_line('hostile smoke test OK (' || l_cnt || ' checks)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_hostile')]'; exception when others then null; end;
end;
/
