--------------------------------------------------------------------------------
-- KMLeon :: smoke test - STYLE_HIGHLIGHT_SCALE (<StyleMap> normal/highlight)
--------------------------------------------------------------------------------
-- With the setting unset the document carries plain <Style id="ks#"> defs and
-- placemarks reference #ks#. With STYLE_HIGHLIGHT_SCALE = 1.5 every style also
-- gets a "ks#h" highlight variant (scales / widths x 1.5, implicit defaults
-- materialised) and a <StyleMap id="ks#m">; placemarks then reference #ks#m.
-- The setting is restored at the end.
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job  number;
  l_a    number;
  l_kml  clob;
  l_prev number := pck_kml_config_dml.get_number('STYLE_HIGHLIGHT_SCALE');

  function build return clob is
  begin
    l_job := pck_kml_job_api.create_job(p_document_name => 'StyleMap smoke', p_output_format => 'KML');
    l_a := pck_kml_job_api.add_asset(p_job_id => l_job,
             p_geometry_geojson => to_clob('{"type":"Point","coordinates":[13.405,52.52]}'),
             p_name => 'icon+label', p_icon_scale => 1.2, p_label_color => 'ffffffff');
    l_a := pck_kml_job_api.add_asset(p_job_id => l_job,
             p_geometry_geojson => to_clob('{"type":"LineString","coordinates":[[13.4,52.52],[8.68,50.11]]}'),
             p_name => 'line no width', p_line_color => 'ff0000ff');
    l_a := pck_kml_job_api.add_asset(p_job_id => l_job,
             p_geometry_geojson => to_clob('{"type":"Polygon","coordinates":[[[13.3,52.4],[13.5,52.4],[13.5,52.6],[13.3,52.4]]]}'),
             p_name => 'poly only', p_poly_color => '7f0000ff', p_poly_fill => 'Y');
    l_a := pck_kml_job_api.add_asset(p_job_id => l_job,
             p_geometry_geojson => to_clob('{"type":"Point","coordinates":[11.58,48.14]}'),
             p_name => 'unstyled');
    commit;
    pck_kml_job_api.run_now(l_job);
    if pck_kml_job_api.get_status(l_job) != 'COMPLETED' then
      raise_application_error(-20999, 'stylemap smoke FAILED: job not completed');
    end if;
    return pck_kml_job_api.get_kml(l_job);
  end build;

  procedure must(p_cond in boolean, p_what in varchar2) is
  begin
    if not p_cond then
      dbms_output.put_line(dbms_lob.substr(l_kml, 3000, 1));
      raise_application_error(-20999, 'stylemap smoke FAILED: ' || p_what);
    end if;
    dbms_output.put_line('OK   ' || p_what);
  end must;
begin
  --- plain (setting off) ------------------------------------------------------
  pck_kml_config_dml.set_number('STYLE_HIGHLIGHT_SCALE', null);
  commit;
  l_kml := build;
  must(instr(l_kml, '<StyleMap') = 0, 'no StyleMap when the setting is off');
  must(instr(l_kml, '<styleUrl>#ks1</styleUrl>') > 0, 'plain styleUrl #ks1');
  must(regexp_count(l_kml, '<Style id="ks[0-9]+">') = 3, 'three shared styles (unstyled placemark has none)');
  pck_kml_jobs_dml.del(l_job);

  --- highlight on --------------------------------------------------------------
  pck_kml_config_dml.set_number('STYLE_HIGHLIGHT_SCALE', 1.5);
  commit;
  l_kml := build;
  must(regexp_count(l_kml, '<StyleMap id="ks[0-9]+m">') = 3, 'one StyleMap per shared style');
  must(regexp_count(l_kml, '<Style id="ks[0-9]+h">') = 3, 'one highlight style per shared style');
  must(instr(l_kml, '<styleUrl>#ks1m</styleUrl>') > 0, 'placemarks reference the StyleMap');
  must(instr(l_kml, '<Pair><key>normal</key><styleUrl>#ks1</styleUrl></Pair><Pair><key>highlight</key><styleUrl>#ks1h</styleUrl></Pair>') > 0, 'StyleMap pairs');
  must(instr(l_kml, '<Style id="ks1h"><IconStyle><scale>1.8</scale></IconStyle>') > 0, 'icon scale 1.2 x 1.5 = 1.8');
  must(instr(l_kml, '<LineStyle><width>1.5</width><color>ff0000ff</color></LineStyle>') > 0, 'implicit line width becomes 1.5');
  must(regexp_like(l_kml, '<Style id="ks3h"><PolyStyle>.*</PolyStyle><LineStyle><width>1\.5</width></LineStyle></Style>'), 'polygon-only highlight gets an outline');
  must(regexp_count(l_kml, '<Placemark>') = 4, 'all four placemarks rendered');
  pck_kml_jobs_dml.del(l_job);

  --- restore ----------------------------------------------------------------------
  pck_kml_config_dml.set_number('STYLE_HIGHLIGHT_SCALE', l_prev);
  commit;
  dbms_output.put_line('stylemap smoke test OK (jobs cleaned up, setting restored)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_stylemap')]'; exception when others then null; end;
exception
  when others then
    pck_kml_config_dml.set_number('STYLE_HIGHLIGHT_SCALE', l_prev);
    commit;
    raise;
end;
/
