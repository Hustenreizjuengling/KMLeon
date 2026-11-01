set define off
set serveroutput on size unlimited
declare
  l_job number; l_a number; l_n number; l_kml clob; l_row kml_jobs%rowtype;
  procedure t(p_case varchar2, p_ok boolean, p_detail varchar2 default null) is
  begin dbms_output.put_line(case when p_ok then 'ok   ' else 'LOOK ' end || rpad(p_case, 62) || ' ' || substr(p_detail, 1, 150)); end;
  function run(p_job number) return varchar2 is
  begin pck_kml_job_api.run_now(p_job); return pck_kml_job_api.get_status(p_job); end;
  function errmsg(p_job number) return varchar2 is r kml_jobs%rowtype; begin r := pck_kml_jobs_dml.get(p_job); return substr(r.error_message,1,120); end;
begin
  dbms_output.put_line('=== 1. create_job validation');
  begin l_job := pck_kml_job_api.create_job(null); t('document_name NULL', false, 'ACCEPTED job ' || l_job); exception when others then t('document_name NULL', true, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job(rpad('x',401,'x')); t('document_name 401 chars', false, 'ACCEPTED ' || l_job); exception when others then t('document_name 401 chars', true, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job('f', p_output_format => 'PDF'); t('output_format PDF', false, 'ACCEPTED ' || l_job); exception when others then t('output_format PDF', true, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job('f', p_output_format => 'kml'); t('output_format lowercase kml', pck_kml_jobs_dml.get(l_job).output_format = 'KML', 'stored ' || pck_kml_jobs_dml.get(l_job).output_format); pck_kml_jobs_dml.del(l_job); exception when others then t('output_format lowercase', false, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job('f', p_priority => null); t('priority NULL', false, 'ACCEPTED ' || l_job); exception when others then t('priority NULL', true, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job('f', p_priority => -5); t('priority -5', true, 'accepted (no range rule) ' || l_job); pck_kml_jobs_dml.del(l_job); exception when others then t('priority -5', true, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job('f', p_notify_email => 'not an email'); t('notify_email garbage', true, 'accepted (no validation) ' || l_job); pck_kml_jobs_dml.del(l_job); exception when others then t('notify_email garbage', true, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job_from_query('q', 'select 1 from dual', p_source_mode => 'BOGUS'); t('source_mode BOGUS', false, 'ACCEPTED ' || l_job); exception when others then t('source_mode BOGUS', true, sqlerrm); end;
  begin l_job := pck_kml_job_api.create_job_from_query('q', '   '); t('source_query blanks', false, 'ACCEPTED ' || l_job); exception when others then t('source_query blanks', true, sqlerrm); end;
  rollback;

  dbms_output.put_line('=== 2. add_asset validation');
  l_job := pck_kml_job_api.create_job('assets', p_output_format => 'KML'); commit;
  begin l_a := pck_kml_job_api.add_asset(999999999, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}'); t('asset for unknown job', false, 'ACCEPTED'); exception when others then t('asset for unknown job', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_geometry_sdo => sdo_geometry(2001,4326,sdo_point_type(3,4,null),null,null)); t('both geometries given', true, 'accepted; SDO wins at render'); exception when others then t('both geometries', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => 'not json'); t('geojson garbage at insert', true, 'accepted (checked at render) asset ' || l_a); exception when others then t('geojson garbage at insert', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_visibility => 'maybe'); t('visibility maybe', false, 'ACCEPTED'); exception when others then t('visibility maybe', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_extrude => 'yes'); t('extrude yes', false, 'ACCEPTED'); exception when others then t('extrude yes', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_line_color => 'red'); t('line_color red (not aabbggrr)', true, 'accepted -> emitted as-is: ' || l_a); exception when others then t('line_color red', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_line_color => 'ff00ff00ff'); t('line_color 10 chars', false, 'ACCEPTED'); exception when others then t('line_color 10 chars', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_icon_scale => -3, p_line_width => -1); t('negative scale/width', true, 'accepted (KML tolerates?)'); exception when others then t('negative scale/width', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_altitude_mode => 'flying'); t('altitude_mode flying', true, 'accepted; WARN at render'); exception when others then t('altitude_mode flying', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_folder_name => rpad('a/',1000,'b')); t('folder 1000 chars', true, 'accepted'); exception when others then t('folder 1000 chars', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_folder_name => rpad('a',1001,'b')); t('folder 1001 chars', false, 'ACCEPTED'); exception when others then t('folder 1001 chars', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_extended_data => '{"a":[1,2],"b":{"c":1},"d":true,"e":null,"f":1.5e3}'); t('ext data nested/array/bool/null', true, 'accepted asset ' || l_a); exception when others then t('ext data nested', true, sqlerrm); end;
  begin l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}', p_extended_data => 'not json'); t('ext data garbage', true, 'accepted; dropped at render'); exception when others then t('ext data garbage', true, sqlerrm); end;
  commit;
  dbms_output.put_line('--- render job with all of the above');
  t('render mixed-garbage job', run(l_job) = 'COMPLETED', 'status ' || pck_kml_job_api.get_status(l_job) || ' ' || errmsg(l_job));
  l_kml := pck_kml_job_api.get_kml(l_job);
  t('  count placemarks', true, regexp_count(l_kml, '<Placemark>') || ' placemarks, kml len ' || dbms_lob.getlength(l_kml));
  t('  color "red" emitted?', instr(l_kml, '<color>red</color>') = 0, case when instr(l_kml, '<color>red</color>') > 0 then 'invalid KML color emitted verbatim' else 'not emitted' end);
  t('  negative scale emitted?', instr(l_kml, '<scale>-3</scale>') = 0, case when instr(l_kml, '<scale>-3</scale>') > 0 then 'negative scale in KML' else 'ok' end);
  t('  nested ext data', true, substr(regexp_substr(l_kml, '<Data name="a">.*?</Data>'),1,80) || ' | ' || substr(regexp_substr(l_kml, '<Data name="d">.*?</Data>'),1,60) || ' | e:' || substr(regexp_substr(l_kml, '<Data name="e">.*?</Data>'),1,60));
  pck_kml_jobs_dml.del(l_job); commit;

  dbms_output.put_line('=== 3. XML / unicode hostile text');
  l_job := pck_kml_job_api.create_job('<script>alert(1)</script> & "quotes" ''apos'' ]]> äöü€ 😀', p_output_format => 'KML', p_description => 'desc <b>bold</b> & ]]> end');
  l_a := pck_kml_job_api.add_asset(l_job, p_geometry_geojson => '{"type":"Point","coordinates":[1,2]}',
           p_name => 'N <tag> & "q" ]]> 😀', p_folder_name => 'A<b>/B&C/]]>D', p_description => to_clob('<p>html</p> ]]> </description><evil/>'),
           p_extended_data => '{"k<>&\"": "v<>&\" ]]>", "unicode😀": "ü"}', p_icon_href => 'http://x/y?a=1&b=2"<');
  commit;
  t('render hostile text job', run(l_job) = 'COMPLETED', errmsg(l_job));
  l_kml := pck_kml_job_api.get_kml(l_job);
  t('  raw <script> in output?', instr(l_kml, '<script>') = 0, 'escaped: ' || case when instr(l_kml, '&lt;script&gt;') > 0 then 'yes' else 'no' end);
  t('  unescaped & outside CDATA?', not regexp_like(regexp_replace(l_kml, '<!\[CDATA\[.*?\]\]>', ''), '&[^a-z#]'), 'bare ampersand check');
  t('  CDATA break neutralised?', regexp_count(l_kml, '\]\]>') = regexp_count(l_kml, '<!\[CDATA\[') + regexp_count(l_kml, '\]\]\]\]><!\[CDATA\[>'), 'cdata ends=' || regexp_count(l_kml, '\]\]>') || ' starts=' || regexp_count(l_kml, '<!\[CDATA\['));
  t('  XML well-formed (xmltype parse)', true, case when xmltype(l_kml) is not null then 'parses' end);
  pck_kml_jobs_dml.del(l_job); commit;
exception when others then dbms_output.put_line('ABORT: ' || sqlerrm || chr(10) || dbms_utility.format_error_backtrace);
end;
/
exit
