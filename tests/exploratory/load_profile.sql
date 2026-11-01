set define off
set serveroutput on size unlimited
set timing off
declare
  l_job number; l_a number; l_r kml_jobs%rowtype; l_t0 timestamp; l_big clob; l_fc clob; l_n number;
  procedure t(p_case varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin dbms_output.put_line(case when p_ok then 'ok   ' else 'LOOK ' end || rpad(p_case, 58) || ' ' || substr(p_detail, 1, 160)); end;
  function ms(p_from timestamp) return varchar2 is begin return round(extract(second from (systimestamp - p_from)) * 1000 + extract(minute from (systimestamp - p_from)) * 60000) || ' ms'; end;
begin
  dbms_output.put_line('=== 10. load');
  -- 10k assets with styles + ext data via GeoJSON bulk (one FeatureCollection)
  dbms_lob.createtemporary(l_fc, true);
  dbms_lob.writeappend(l_fc, length2('{"type":"FeatureCollection","features":['), '{"type":"FeatureCollection","features":[');
  for i in 1 .. 10000 loop
    declare s varchar2(400) := '{"type":"Feature","geometry":{"type":"Point","coordinates":[' || (mod(i,360)-180) || ',' || (mod(i,170)-85) || ']},"properties":{"NAME":"p' || i || '","FOLDER_NAME":"F' || mod(i,20) || '/S' || mod(i,5) || '","ICON_SCALE":' || (1 + mod(i,3)) || ',"LINE_COLOR":"ff0000ff","k":"v' || i || '"}}' || case when i < 10000 then ',' end;
    begin dbms_lob.writeappend(l_fc, length2(s), s); end;
  end loop;
  dbms_lob.writeappend(l_fc, 2, ']}');
  l_job := pck_kml_job_api.create_job('load 10k', p_output_format => 'KMZ'); commit;
  l_t0 := systimestamp; l_n := pck_kml_job_api.add_features_geojson(l_job, l_fc); commit;
  t('ingest 10k features via GeoJSON', l_n = 10000, l_n || ' in ' || ms(l_t0));
  l_t0 := systimestamp; pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job);
  t('render 10k -> KMZ', l_r.status = 'COMPLETED' and l_r.asset_count = 10000, l_r.status || ' ' || l_r.asset_count || ' feats, kmz ' || l_r.result_size_bytes || ' bytes in ' || ms(l_t0));
  pck_kml_jobs_dml.del(l_job); commit;

  -- 1 MB description + 2000-key ExtendedData on a single asset, KML out
  dbms_lob.createtemporary(l_big, true);
  for i in 1 .. 1024 loop dbms_lob.writeappend(l_big, 1024, rpad('<p>' || i || ' lorem ipsum ]]> & <b>x</b>', 1024, 'x')); end loop;
  l_job := pck_kml_job_api.create_job('load bigdesc', p_output_format => 'KML');
  declare l_ext clob; begin
    select json_objectagg('key' || level value rpad('v', 200, 'v') returning clob) into l_ext from dual connect by level <= 2000;
    l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_description => l_big, p_extended_data => l_ext);
  end;
  commit;
  l_t0 := systimestamp; pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job);
  t('1 MB description + 2000 ext keys', l_r.status = 'COMPLETED' and dbms_lob.getlength(l_r.result_kml) > 1400000, l_r.status || ' kml ' || dbms_lob.getlength(l_r.result_kml) || ' chars in ' || ms(l_t0));
  begin t('  well-formed', xmltype(l_r.result_kml) is not null, 'xmltype parses'); exception when others then t('  well-formed', false, sqlerrm); end;
  pck_kml_jobs_dml.del(l_job); commit;

  -- ~12 MB KML -> KMZ via QUERY stream (50k points with long descriptions)
  l_job := pck_kml_job_api.create_job_from_query('load 12MB kmz', p_output_format => 'KMZ',
    p_source_query => q'[select sdo_geometry(2001,4326,sdo_point_type(mod(level,360)-180, mod(level,170)-85, null),null,null) as geometry,
                                'point ' || level as name, 'F' || mod(level,50) as folder_name, rpad('desc ', 200, 'd') as description, level as seq
                           from dual connect by level <= 50000 order by 3]');
  commit;
  l_t0 := systimestamp; pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job);
  t('50k streamed points -> KMZ', l_r.status = 'COMPLETED' and l_r.asset_count = 50000, l_r.status || ' ' || l_r.asset_count || ' feats, kmz ' || round(l_r.result_size_bytes/1024) || ' KB in ' || ms(l_t0));
  declare l_doc blob; begin l_doc := pck_kml_zip.get_file(l_r.result_kmz, 'doc.kml'); t('  kmz readable, doc.kml size', l_doc is not null, round(dbms_lob.getlength(l_doc)/1024/1024, 1) || ' MB'); end;
  pck_kml_jobs_dml.del(l_job); commit;

  -- deep folder nesting + 500 distinct styles (style registry key 32k)
  l_job := pck_kml_job_api.create_job_from_query('load styles', p_output_format => 'KML',
    p_source_query => q'[select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, 'n' as name,
                                regexp_replace(rpad('L', 2*level, 'L/'), '/$', '') as folder_name,
                                lpad(to_char(mod(level,500), 'FM0XXXXXXX'), 8, '0') as line_color, level as line_width
                           from dual connect by level <= 1000 order by 3]');
  commit;
  l_t0 := systimestamp; pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job);
  t('1000 rows, 500 styles, folders nested 1000 deep', l_r.status = 'COMPLETED', l_r.status || ' ' || l_r.asset_count || ' feats, styles=' || regexp_count(l_r.result_kml, '<Style id=') || ' in ' || ms(l_t0) || ' ' || substr(l_r.error_message,1,80));
  begin t('  well-formed', xmltype(l_r.result_kml) is not null, 'parses'); exception when others then t('  well-formed', false, sqlerrm); end;
  pck_kml_jobs_dml.del(l_job); commit;
  select count(*) into l_n from v$temporary_lobs where sid = sys_context('userenv','sid');
  t('temp lobs left in session after load tests', true, 'cache_lobs+nocache_lobs rows: ' || l_n);
exception when others then dbms_output.put_line('ABORT ' || sqlerrm || chr(10) || dbms_utility.format_error_backtrace);
end;
/
select cache_lobs, nocache_lobs, abstract_lobs from v$temporary_lobs where sid = sys_context('userenv','sid');
exit
