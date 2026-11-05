set define off
set serveroutput on size unlimited
declare
  l_job number; l_a number; l_kml clob; l_r kml_jobs%rowtype; l_c pls_integer;
  procedure t(p_case varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin dbms_output.put_line(case when p_ok then 'ok   ' else 'LOOK ' end || rpad(p_case, 62) || ' ' || substr(p_detail, 1, 160)); end;
  function g2k(p_g sdo_geometry) return varchar2 is begin return dbms_lob.substr(pck_kml_geom.to_kml(p_g), 150, 1); exception when others then return 'ERR ' || substr(sqlerrm, 1, 100); end;
  function j2k(p_j varchar2) return varchar2 is begin return dbms_lob.substr(pck_kml_geom.to_kml(pck_kml_geom.from_geojson(p_j)), 150, 1); exception when others then return 'ERR ' || substr(sqlerrm, 1, 100); end;
  function qjob(p_sql clob, p_binds clob default null, p_mode varchar2 default 'STREAM') return varchar2 is
  begin
    l_job := pck_kml_job_api.create_job_from_query('q', p_sql, p_binds, p_mode, p_output_format => 'KML'); commit;
    pck_kml_job_api.run_now(l_job); l_r := pck_kml_jobs_dml.get(l_job);
    return l_r.status || ' feats=' || nvl(l_r.asset_count, 0) || ' ' || substr(l_r.error_message, 1, 110);
  end;
begin
  dbms_output.put_line('=== 4. geometry edge cases (pure PL/SQL serializer)');
  t('empty geometry (no point, no ordinates)', true, nvl(g2k(sdo_geometry(2001, 4326, null, null, null)), '<null>'));
  t('gtype 2000 (unknown type)', true, nvl(g2k(sdo_geometry(2000, 4326, null, sdo_elem_info_array(1,1,1), sdo_ordinate_array(1,2))), '<null>'));
  t('point with NULL ordinate', true, nvl(g2k(sdo_geometry(2001, 4326, sdo_point_type(1, null, null), null, null)), '<null>'));
  t('line with 1 vertex', true, nvl(g2k(sdo_geometry(2002, 4326, null, sdo_elem_info_array(1,2,1), sdo_ordinate_array(1,2))), '<null>'));
  t('polygon 3 vertices unclosed', true, nvl(g2k(sdo_geometry(2003, 4326, null, sdo_elem_info_array(1,1003,1), sdo_ordinate_array(0,0,1,0,1,1))), '<null>'));
  t('elem_info offset beyond ordinates', true, nvl(g2k(sdo_geometry(2002, 4326, null, sdo_elem_info_array(1,2,1, 99,2,1), sdo_ordinate_array(1,2,3,4))), '<null>'));
  t('odd ordinate count', true, nvl(g2k(sdo_geometry(2002, 4326, null, sdo_elem_info_array(1,2,1), sdo_ordinate_array(1,2,3))), '<null>'));
  t('inner ring only (2003 w/o 1003)', true, nvl(g2k(sdo_geometry(2003, 4326, null, sdo_elem_info_array(1,2003,1), sdo_ordinate_array(0,0,0,1,1,1,1,0,0,0))), '<null>'));
  t('huge coordinates 1e30', true, nvl(g2k(sdo_geometry(2001, null, sdo_point_type(1e30, -1e30, null), null, null)), '<null>'));
  t('tiny coordinates 1e-30', true, nvl(g2k(sdo_geometry(2001, null, sdo_point_type(1e-30, 5e-31, null), null, null)), '<null>'));
  t('lat 95 lon 190 (out of range)', true, nvl(g2k(sdo_geometry(2001, 4326, sdo_point_type(190, 95, null), null, null)), '<null>'));
  t('4D point (4001) x,y,z,m', true, nvl(g2k(sdo_geometry(4001, 4326, null, sdo_elem_info_array(1,1,1), sdo_ordinate_array(1,2,3,4))), '<null>'));
  t('geodetic arc (invalid in 4326)', true, nvl(g2k(sdo_geometry(2002, 4326, null, sdo_elem_info_array(1,2,2), sdo_ordinate_array(0,0,1,1,2,0))), '<null>'));
  t('circle 1003/4 (3 points)', true, nvl(g2k(sdo_geometry(2003, null, null, sdo_elem_info_array(1,1003,4), sdo_ordinate_array(0,0,1,1,2,0))), '<null>'));
  t('compound line 4', true, nvl(g2k(sdo_geometry(2002, null, null, sdo_elem_info_array(1,4,2, 1,2,1, 3,2,2), sdo_ordinate_array(0,0,1,1, 2,2,3,1))), '<null>'));
  t('oriented point (1,1,0 orientation)', true, nvl(g2k(sdo_geometry(2001, 4326, null, sdo_elem_info_array(1,1,1, 3,1,0), sdo_ordinate_array(1,2, 0.5,0.5))), '<null>'));
  t('SRID 3857 polygon', true, nvl(g2k(sdo_geometry(2003, 3857, null, sdo_elem_info_array(1,1003,1), sdo_ordinate_array(1492000,6894000, 1493000,6894000, 1493000,6895000, 1492000,6894000))), '<null>'));
  dbms_output.put_line('--- GeoJSON edge cases');
  t('geojson empty coordinates', true, nvl(j2k('{"type":"Point","coordinates":[]}'), '<null>'));
  t('geojson lon/lat swapped-looking', true, nvl(j2k('{"type":"Point","coordinates":[52.5,13.4]}'), '<null>'));
  t('geojson strings as coords', true, nvl(j2k('{"type":"Point","coordinates":["1","2"]}'), '<null>'));
  t('geojson unknown type', true, nvl(j2k('{"type":"Circle","coordinates":[1,2]}'), '<null>'));
  t('geojson GeometryCollection empty', true, nvl(j2k('{"type":"GeometryCollection","geometries":[]}'), '<null>'));
  t('geojson FeatureCollection no features key', true, nvl(j2k('{"type":"FeatureCollection"}'), '<null>'));
  t('geojson Feature geometry null', true, nvl(j2k('{"type":"Feature","geometry":null,"properties":{}}'), '<null>'));
  t('geojson with crs/bbox extras', true, nvl(j2k('{"type":"Point","bbox":[1,2,1,2],"coordinates":[1,2],"crs":{"type":"name"}}'), '<null>'));
  t('geojson MultiPolygon w/ hole', true, nvl(j2k('{"type":"MultiPolygon","coordinates":[[[[0,0],[4,0],[4,4],[0,4],[0,0]],[[1,1],[1,2],[2,2],[2,1],[1,1]]],[[[10,10],[11,10],[11,11],[10,10]]]]}'), '<null>'));
  declare l_big clob; begin
    dbms_lob.createtemporary(l_big, true); dbms_lob.writeappend(l_big, 36, '{"type":"LineString","coordinates":[');
    for i in 1 .. 20000 loop dbms_lob.writeappend(l_big, length('[' || (i/1000) || ',' || (i/2000) || ']' || case when i < 20000 then ',' end), '[' || (i/1000) || ',' || (i/2000) || ']' || case when i < 20000 then ',' end); end loop;
    dbms_lob.writeappend(l_big, 2, ']}');
    t('geojson 20k-vertex line (' || dbms_lob.getlength(l_big) || ' chars)', true, substr(nvl(dbms_lob.substr(pck_kml_geom.to_kml(pck_kml_geom.from_geojson(l_big)), 60, 1), '<null>'), 1, 60));
  exception when others then t('geojson 20k-vertex line', false, sqlerrm); end;

  dbms_output.put_line('=== 5. QUERY source hostility');
  begin t('DDL in query', true, qjob('create table pwned(x int)')); exception when others then t('DDL in query', true, 'rejected at create: ' || sqlerrm); end;
  begin t('DML in query', true, qjob('delete from kml_log')); exception when others then t('DML in query', true, 'rejected at create: ' || sqlerrm); end;
  begin t('comment-prefixed DDL', true, qjob('/* x */ -- y' || chr(10) || 'create table pwned(x int)')); exception when others then t('comment-prefixed DDL', true, 'rejected at create: ' || sqlerrm); end;
  begin t('WITH query ok', true, qjob('with g as (select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry from dual) select * from g')); exception when others then t('WITH query', false, sqlerrm); end;
  begin t('PL/SQL block in query', true, qjob('begin null; end;')); exception when others then t('PL/SQL block in query', true, 'rejected at create: ' || sqlerrm); end;
  t('select without geometry alias', true, qjob('select ''x'' as name from dual'));
  t('geometry alias on varchar col', true, qjob('select ''POINT(1 2)'' as geometry, ''x'' as name from dual'));
  t('GEOMETRY_GEOJSON garbage', true, qjob('select ''nope'' as geometry_geojson from dual'));
  t('GEOMETRY_KML passthrough garbage', true, qjob('select ''<Point><coordinates>1,2</coordinates></Point>'' as geometry_kml, ''ok'' as name from dual'));
  t('GEOMETRY_KML passthrough broken xml', true, qjob('select ''<Point><coordinates>1,2'' as geometry_kml from dual'));
  t('missing bind', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, :x as name from dual'));
  t('extra bind in json', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry from dual', '{"unused":"v"}'));
  t('binds not json', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry from dual', 'not json'));
  t('bind number vs string compare', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, :n + 1 as plus from dual', '{"n":41}'));
  t('unsupported type (RAW, BLOB)', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, hextoraw(''FF'') as r, to_blob(hextoraw(''FF'')) as b from dual'));
  t('duplicate aliases', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, 1 as name, 2 as name from dual'));
  t('column without alias (expression)', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, 1+1 from dual'));
  t('sleep/time bomb 3s', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, pck_kmleon_tools.row_sleep(3) as s from dual'));
  t('MATERIALIZE with GEOMETRY_KML', true, qjob('select ''<Point><coordinates>1,2</coordinates></Point>'' as geometry_kml from dual', null, 'MATERIALIZE'));
  t('MATERIALIZE 500 rows', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(level/10,level/20,null),null,null) as geometry, ''p''||level as name from dual connect by level <= 500', null, 'MATERIALIZE'));
  t('STREAM 5000 rows w/ folders', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(mod(level,360)-180,mod(level,170)-85,null),null,null) as geometry, ''p''||level as name, ''F''||mod(level,7)||''/S''||mod(level,3) as folder_name from dual connect by level <= 5000 order by 3'));
  t('query referencing other schema table', true, qjob('select * from sys.dba_users'));
  t('query selecting own kml_jobs (info leak via QUERY)', true, qjob('select sdo_geometry(2001,4326,sdo_point_type(1,2,null),null,null) as geometry, access_key as name from kml_jobs where rownum = 1'));
  for r in (select job_id from kml_jobs where document_name = 'q') loop pck_kml_jobs_dml.del(r.job_id); end loop;
  begin execute immediate 'drop table pwned purge'; dbms_output.put_line('LOOK  table pwned EXISTED (DDL ran)'); exception when others then null; end;
  commit;
exception when others then dbms_output.put_line('ABORT: ' || sqlerrm || chr(10) || dbms_utility.format_error_backtrace);
end;
/
exit
