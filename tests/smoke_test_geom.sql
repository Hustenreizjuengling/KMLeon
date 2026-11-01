--------------------------------------------------------------------------------
-- KMLeon :: smoke test - PCK_KML_GEOM (pure PL/SQL SDO_GEOMETRY -> KML)
--------------------------------------------------------------------------------
-- Asserts the exact KML fragments for every geometry shape KMLeon has to
-- handle, plus: arc densification, optimized rectangles, LRS measure removal,
-- projected -> WGS84 transformation, GeoJSON Feature / FeatureCollection input
-- and the error contract. Needs Spatial only -- NO Oracle JVM.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set lines 200

declare
  l_n   pls_integer := 0;
  l_got clob;
  l_sdo sdo_geometry;

  procedure eq(p_name in varchar2, p_geom in sdo_geometry, p_expect in varchar2) is
    l clob := pck_kml_geom.to_kml(p_geom);
  begin
    l_n := l_n + 1;
    if l is null and p_expect is null then
      dbms_output.put_line('OK   ' || p_name);
    elsif l is null or dbms_lob.compare(l, to_clob(p_expect)) <> 0 then
      dbms_output.put_line('FAIL ' || p_name);
      dbms_output.put_line('     expected: ' || p_expect);
      dbms_output.put_line('     got     : ' || dbms_lob.substr(l, 3000, 1));
      raise_application_error(-20999, 'geom smoke FAILED: ' || p_name);
    else
      dbms_output.put_line('OK   ' || p_name);
    end if;
  end eq;

  procedure ok(p_name in varchar2, p_cond in boolean, p_detail in varchar2 default null) is
  begin
    l_n := l_n + 1;
    if p_cond then
      dbms_output.put_line('OK   ' || p_name);
    else
      dbms_output.put_line('FAIL ' || p_name || ' -- ' || p_detail);
      raise_application_error(-20999, 'geom smoke FAILED: ' || p_name);
    end if;
  end ok;
begin
  --- points -------------------------------------------------------------------
  eq('point 2D (sdo_point)',
     sdo_geometry(2001, 4326, sdo_point_type(13.405, 52.52, null), null, null),
     '<Point><coordinates>13.405,52.52</coordinates></Point>');
  eq('point 3D (sdo_point, altitude kept)',
     sdo_geometry(3001, 4326, sdo_point_type(13.405, 52.52, 150), null, null),
     '<Point><coordinates>13.405,52.52,150</coordinates></Point>');
  eq('point via ordinates',
     sdo_geometry(2001, 4326, null, sdo_elem_info_array(1, 1, 1), sdo_ordinate_array(1, 2)),
     '<Point><coordinates>1,2</coordinates></Point>');
  eq('number format: leading zero, negatives, no exponent',
     sdo_geometry(2001, 4326, sdo_point_type(-0.5, 0.000001, null), null, null),
     '<Point><coordinates>-0.5,0.000001</coordinates></Point>');
  eq('multipoint (point cluster)',
     sdo_geometry(2005, 4326, null, sdo_elem_info_array(1, 1, 3), sdo_ordinate_array(1, 2, 3, 4, 5, 6)),
     '<MultiGeometry><Point><coordinates>1,2</coordinates></Point><Point><coordinates>3,4</coordinates></Point>'
     || '<Point><coordinates>5,6</coordinates></Point></MultiGeometry>');

  --- lines --------------------------------------------------------------------
  eq('linestring',
     sdo_geometry(2002, 4326, null, sdo_elem_info_array(1, 2, 1),
                  sdo_ordinate_array(13.40, 52.52, 11.58, 48.14, 8.68, 50.11)),
     '<LineString><coordinates>13.4,52.52 11.58,48.14 8.68,50.11</coordinates></LineString>');
  eq('linestring 3D',
     sdo_geometry(3002, 4326, null, sdo_elem_info_array(1, 2, 1), sdo_ordinate_array(1, 2, 100, 3, 4, 200)),
     '<LineString><coordinates>1,2,100 3,4,200</coordinates></LineString>');
  eq('LRS line: measure dropped',
     sdo_geometry(3302, 4326, null, sdo_elem_info_array(1, 2, 1), sdo_ordinate_array(1, 2, 0, 3, 4, 10)),
     '<LineString><coordinates>1,2 3,4</coordinates></LineString>');
  eq('multilinestring',
     sdo_geometry(2006, 4326, null, sdo_elem_info_array(1, 2, 1, 5, 2, 1), sdo_ordinate_array(0, 0, 1, 1, 5, 5, 6, 6)),
     '<MultiGeometry><LineString><coordinates>0,0 1,1</coordinates></LineString>'
     || '<LineString><coordinates>5,5 6,6</coordinates></LineString></MultiGeometry>');

  --- polygons -----------------------------------------------------------------
  eq('polygon with hole',
     sdo_geometry(2003, 4326, null, sdo_elem_info_array(1, 1003, 1, 11, 2003, 1),
                  sdo_ordinate_array(0, 0, 10, 0, 10, 10, 0, 10, 0, 0,  2, 2, 2, 4, 4, 4, 4, 2, 2, 2)),
     '<Polygon><outerBoundaryIs><LinearRing><coordinates>0,0 10,0 10,10 0,10 0,0</coordinates></LinearRing></outerBoundaryIs>'
     || '<innerBoundaryIs><LinearRing><coordinates>2,2 2,4 4,4 4,2 2,2</coordinates></LinearRing></innerBoundaryIs></Polygon>');
  eq('polygon: unclosed ring gets closed',
     sdo_geometry(2003, 4326, null, sdo_elem_info_array(1, 1003, 1), sdo_ordinate_array(0, 0, 1, 0, 1, 1, 0, 1)),
     '<Polygon><outerBoundaryIs><LinearRing><coordinates>0,0 1,0 1,1 0,1 0,0</coordinates></LinearRing></outerBoundaryIs></Polygon>');
  eq('optimized rectangle expanded',
     sdo_geometry(2003, 4326, null, sdo_elem_info_array(1, 1003, 3), sdo_ordinate_array(0, 0, 2, 1)),
     '<Polygon><outerBoundaryIs><LinearRing><coordinates>0,0 2,0 2,1 0,1 0,0</coordinates></LinearRing></outerBoundaryIs></Polygon>');
  eq('multipolygon',
     sdo_geometry(2007, 4326, null, sdo_elem_info_array(1, 1003, 1, 11, 1003, 1),
                  sdo_ordinate_array(0, 0, 1, 0, 1, 1, 0, 1, 0, 0,  5, 5, 6, 5, 6, 6, 5, 6, 5, 5)),
     '<MultiGeometry><Polygon><outerBoundaryIs><LinearRing><coordinates>0,0 1,0 1,1 0,1 0,0</coordinates></LinearRing></outerBoundaryIs></Polygon>'
     || '<Polygon><outerBoundaryIs><LinearRing><coordinates>5,5 6,5 6,6 5,6 5,5</coordinates></LinearRing></outerBoundaryIs></Polygon></MultiGeometry>');

  --- collection ---------------------------------------------------------------
  eq('geometry collection',
     sdo_geometry(2004, 4326, null, sdo_elem_info_array(1, 1, 1, 3, 2, 1), sdo_ordinate_array(1, 2, 3, 4, 5, 6)),
     '<MultiGeometry><Point><coordinates>1,2</coordinates></Point>'
     || '<LineString><coordinates>3,4 5,6</coordinates></LineString></MultiGeometry>');

  --- arcs: densified into straight segments -------------------------------------
  l_got := pck_kml_geom.to_kml(sdo_geometry(2002, null, null, sdo_elem_info_array(1, 2, 2), sdo_ordinate_array(0, 0, 1, 1, 2, 0)));
  ok('arc densified (starts/ends right, > 3 vertices)',
     l_got like '<LineString><coordinates>0,0 %2,0</coordinates></LineString>'
     and regexp_count(l_got, ' ') > 3, dbms_lob.substr(l_got, 300, 1));

  --- projected input -> lon/lat --------------------------------------------------
  l_got := pck_kml_geom.to_kml(sdo_geometry(2001, 25832, sdo_point_type(391000, 5820000, null), null, null));
  ok('UTM 32N transformed to WGS84', l_got like '<Point><coordinates>7.39354%,52.5191%</coordinates></Point>', dbms_lob.substr(l_got, 300, 1));
  l_got := pck_kml_geom.to_kml(sdo_geometry(2001, 25832, sdo_point_type(391000, 5820000, null), null, null), p_transform => false);
  ok('transform can be switched off', l_got = '<Point><coordinates>391000,5820000</coordinates></Point>', dbms_lob.substr(l_got, 300, 1));

  --- GeoJSON input ---------------------------------------------------------------
  eq('geojson bare geometry', pck_kml_geom.from_geojson('{"type":"Point","coordinates":[13.405,52.52]}'),
     '<Point><coordinates>13.405,52.52</coordinates></Point>');
  eq('geojson Feature unwrapped',
     pck_kml_geom.from_geojson('{"type":"Feature","geometry":{"type":"Point","coordinates":[13.405,52.52]},"properties":{"a":1}}'),
     '<Point><coordinates>13.405,52.52</coordinates></Point>');
  eq('geojson FeatureCollection -> MultiGeometry',
     pck_kml_geom.from_geojson('{"type":"FeatureCollection","features":['
       || '{"type":"Feature","geometry":{"type":"Point","coordinates":[1,2]},"properties":{}},'
       || '{"type":"Feature","geometry":{"type":"LineString","coordinates":[[3,4],[5,6]]},"properties":{}}]}'),
     '<MultiGeometry><Point><coordinates>1,2</coordinates></Point>'
     || '<LineString><coordinates>3,4 5,6</coordinates></LineString></MultiGeometry>');
  eq('geojson polygon with hole',
     pck_kml_geom.from_geojson('{"type":"Polygon","coordinates":[[[0,0],[10,0],[10,10],[0,10],[0,0]],[[2,2],[2,4],[4,4],[4,2],[2,2]]]}'),
     '<Polygon><outerBoundaryIs><LinearRing><coordinates>0,0 10,0 10,10 0,10 0,0</coordinates></LinearRing></outerBoundaryIs>'
     || '<innerBoundaryIs><LinearRing><coordinates>2,2 2,4 4,4 4,2 2,2</coordinates></LinearRing></innerBoundaryIs></Polygon>');
  l_sdo := pck_kml_geom.from_geojson('{"type":"Point","coordinates":[13.4094,52.5219,150]}');
  l_got := pck_kml_geom.to_kml(l_sdo);
  dbms_output.put_line('     geojson 3D point -> gtype ' || l_sdo.sdo_gtype || ' srid ' || l_sdo.sdo_srid || ' -> ' || l_got);
  ok('geojson 3D point keeps altitude', l_got = '<Point><coordinates>13.4094,52.5219,150</coordinates></Point>', dbms_lob.substr(l_got, 300, 1));

  --- edge / error contract -------------------------------------------------------
  eq('null geometry -> null', null, null);
  ok('empty geojson -> null', pck_kml_geom.from_geojson(null) is null);
  ok('fmt', pck_kml_geom.fmt(10) = '10' and pck_kml_geom.fmt(0.5) = '0.5' and pck_kml_geom.fmt(-2.25) = '-2.25' and pck_kml_geom.fmt(1000000) = '1000000',
     pck_kml_geom.fmt(10) || '/' || pck_kml_geom.fmt(0.5) || '/' || pck_kml_geom.fmt(-2.25));
  begin
    l_got := pck_kml_geom.to_kml(sdo_geometry(3008, null, null, sdo_elem_info_array(1, 1007, 1), sdo_ordinate_array(0, 0, 0)));
    raise_application_error(-20999, 'geom smoke FAILED: solid was accepted');
  exception when others then
    if sqlcode != -20830 then raise; end if;
  end;
  l_n := l_n + 1;
  dbms_output.put_line('OK   solid rejected with -20830');

  dbms_output.put_line('--------------------------------------------------');
  dbms_output.put_line('geom smoke test OK (' || l_n || ' checks)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_geom')]'; exception when others then null; end;
end;
/
