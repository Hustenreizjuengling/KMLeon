--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_GEOM  (pure PL/SQL geometry conversion -- no Oracle JVM)
--------------------------------------------------------------------------------
-- SDO_GEOMETRY -> KML geometry fragment, written in plain PL/SQL. It replaces
-- SDO_UTIL.TO_KMLGEOMETRY, which is implemented in Java and therefore raises
-- ORA-29538 ("Java not installed") on every database without the OJVM component
-- (e.g. Oracle Database Free container images, hardened/minimal installs).
-- Everything this package calls (SDO_GEOM.SDO_ARC_DENSIFY, SDO_CS.TRANSFORM,
-- SDO_UTIL.FROM_GEOJSON) is native C/PLSQL and works without Java.
--
-- Output mirrors TO_KMLGEOMETRY: <Point>, <LineString>, <Polygon> (with
-- <outerBoundaryIs>/<innerBoundaryIs>) or a <MultiGeometry> around several
-- parts. No <extrude>/<tessellate>/<altitudeMode> tags are emitted -- the engine
-- injects those from the asset's placement columns (version-neutral output).
--
-- Beyond TO_KMLGEOMETRY it also
--   * transforms non-WGS84 geometries to lon/lat (SDO_CS.TRANSFORM), since KML
--     is WGS84-only -- previously a projected geometry produced garbage KML;
--   * densifies circular arcs / compound elements and expands optimized
--     rectangles and circles (KML has straight segments only);
--   * drops LRS measure ordinates (KML coordinates are lon,lat[,alt]).
--
-- No dependency on other KMLeon packages (reusable on its own).
--------------------------------------------------------------------------------

create or replace package pck_kml_geom
  authid definer
as
  -- Serialize an SDO_GEOMETRY as a KML geometry fragment. NULL in -> NULL out.
  -- p_transform : transform to WGS84 when the SRID is not already lon/lat WGS84.
  --               A transformation that fails raises -20831 (never silently
  --               emits projected ordinates as lon/lat).
  -- p_tolerance / p_arc_tolerance : passed to SDO_GEOM.SDO_ARC_DENSIFY when the
  --               geometry contains arcs / optimized rectangles (units of the
  --               geometry's SRS; Oracle requires arc_tolerance > tolerance).
  -- p_point_tags / p_line_tags : XML inserted right after every <Point> resp.
  --               <LineString>/<Polygon> opening tag (KML placement tags such as
  --               <extrude>/<altitudeMode>; KML requires them before the
  --               coordinates). Lets the caller avoid post-processing the CLOB.
  -- Raises -20830 for geometry types KML cannot express (solids, unknown etypes).
  function to_kml(
    p_geom          in sdo_geometry,
    p_transform     in boolean  default true,
    p_tolerance     in number   default 0.005,
    p_arc_tolerance in number   default 0.05,
    p_point_tags    in varchar2 default null,
    p_line_tags     in varchar2 default null
  ) return clob;

  -- GeoJSON text -> SDO_GEOMETRY via SDO_UTIL.FROM_GEOJSON, accepting what the
  -- data model promises: a bare geometry, a Feature (its geometry is used) or a
  -- FeatureCollection (all geometries -> one GeometryCollection). FROM_GEOJSON
  -- itself only takes bare geometries. NULL/empty in -> NULL out.
  function from_geojson(p_geojson in clob) return sdo_geometry;

  -- TRUE when the SRID is a lon/lat WGS84 system KML can take unchanged.
  function is_wgs84(p_srid in number) return boolean;

  -- Map helpers (SQL-callable, NULL on any error -- a single bad geometry must
  -- not break a map region or an extent query):
  --   to_sdo_wgs84 : the asset's geometry (SDO preferred, else GeoJSON geometry /
  --                  Feature / FeatureCollection) as SDO_GEOMETRY in WGS84.
  --   map_geojson  : the same as a GeoJSON *geometry* string (what map layers eat).
  function to_sdo_wgs84(p_sdo in sdo_geometry, p_geojson in clob) return sdo_geometry;
  function map_geojson(p_sdo in sdo_geometry, p_geojson in clob) return clob;

  -- Number -> KML text (NLS-safe, no exponent, no trailing zeros).
  function fmt(p_value in number) return varchar2;

end pck_kml_geom;
/

create or replace package body pck_kml_geom
as
  c_max_buf constant pls_integer := 32000;

  -- element types / interpretations (SDO_ELEM_INFO_ARRAY)
  c_et_point     constant pls_integer := 1;
  c_et_line      constant pls_integer := 2;
  c_et_compound  constant pls_integer := 4;
  c_et_outer     constant pls_integer := 1003;
  c_et_inner     constant pls_integer := 2003;
  c_et_outer_cmp constant pls_integer := 1005;
  c_et_inner_cmp constant pls_integer := 2005;
  c_ip_straight  constant pls_integer := 1;
  c_ip_arc       constant pls_integer := 2;
  c_ip_rect      constant pls_integer := 3;
  c_ip_circle    constant pls_integer := 4;

  -- buffered CLOB writer: collect in a varchar2 and flush in big chunks
  type t_out is record (lob clob, buf varchar2(32767));

  procedure put(io in out nocopy t_out, p_text in varchar2) is
  begin
    if p_text is null then
      return;
    end if;
    if nvl(length(io.buf), 0) + length(p_text) > c_max_buf then
      if io.buf is not null then
        dbms_lob.writeappend(io.lob, length(io.buf), io.buf);
        io.buf := null;
      end if;
    end if;
    io.buf := io.buf || p_text;
  end put;

  procedure flush(io in out nocopy t_out) is
  begin
    if io.buf is not null then
      dbms_lob.writeappend(io.lob, length(io.buf), io.buf);
      io.buf := null;
    end if;
  end flush;


  function fmt(p_value in number) return varchar2 is
    l varchar2(80);
  begin
    if p_value is null then
      return null;
    end if;
    -- TM9 = shortest fixed-point text (no trailing zeros); force '.' as the
    -- decimal separator and add the leading zero TM9 omits (".5" -> "0.5")
    l := to_char(p_value, 'TM9', 'NLS_NUMERIC_CHARACTERS=''.,''');
    if substr(l, 1, 1) = '.' then
      l := '0' || l;
    elsif substr(l, 1, 2) = '-.' then
      l := '-0' || substr(l, 2);
    end if;
    return l;
  end fmt;


  function is_wgs84(p_srid in number) return boolean is
  begin
    -- EPSG 4326 (2D) / 4979 (3D); Oracle legacy 8307 (2D), 4327 / 4329 (3D)
    return p_srid is null or p_srid in (4326, 4979, 8307, 4327, 4329);
  end is_wgs84;


  -- does the element array hold anything that is not straight-line / point data?
  function needs_densify(p_ei in sdo_elem_info_array) return boolean is
    l_et pls_integer;
    l_ip pls_integer;
  begin
    if p_ei is null then
      return false;
    end if;
    for e in 1 .. trunc(p_ei.count / 3) loop
      l_et := p_ei(3 * e - 1);
      l_ip := p_ei(3 * e);
      if l_et in (c_et_compound, c_et_outer_cmp, c_et_inner_cmp) then
        return true;
      end if;
      -- arcs/circles (KML has straight segments only) and optimized rectangles (two
      -- corners -- must become a ring BEFORE any coordinate transformation)
      if l_et in (c_et_line, c_et_outer, c_et_inner) and l_ip in (c_ip_arc, c_ip_rect, c_ip_circle) then
        return true;
      end if;
    end loop;
    return false;
  end needs_densify;


  function to_kml(
    p_geom          in sdo_geometry,
    p_transform     in boolean  default true,
    p_tolerance     in number   default 0.005,
    p_arc_tolerance in number   default 0.05,
    p_point_tags    in varchar2 default null,
    p_line_tags     in varchar2 default null
  ) return clob is
    l_g      sdo_geometry := p_geom;
    l_gtype  pls_integer;
    l_dims   pls_integer;
    l_lrs    pls_integer;
    l_ttype  pls_integer;
    l_zoff   pls_integer;          -- offset of the altitude ordinate within a tuple (0-based), NULL = 2D out
    l_ei     sdo_elem_info_array;
    l_ord    sdo_ordinate_array;
    l_ntrip  pls_integer;
    l_parts  pls_integer := 0;     -- top-level KML geometries (decides <MultiGeometry>)
    l_out    t_out;
    l_in_poly boolean := false;    -- a <Polygon> is open (waiting for inner rings)

    -- one coordinate tuple at ordinate index p_i (1-based, points at x)
    function tuple(p_i in pls_integer) return varchar2 is
    begin
      return fmt(l_ord(p_i)) || ',' || fmt(l_ord(p_i + 1))
             || case when l_zoff is not null and l_ord(p_i + l_zoff) is not null
                     then ',' || fmt(l_ord(p_i + l_zoff)) end;
    end tuple;

    -- write "<coordinates>t1 t2 ...</coordinates>" for ordinates p_from .. p_to-1
    procedure coordinates(p_from in pls_integer, p_to in pls_integer, p_close in boolean) is
      l_i     pls_integer := p_from;
      l_first varchar2(200);
      l_last  varchar2(200);
      l_t     varchar2(200);
    begin
      put(l_out, '<coordinates>');
      while l_i + 1 <= p_to - 1 loop
        l_t := tuple(l_i);
        if l_first is null then
          l_first := l_t;
        else
          put(l_out, ' ');
        end if;
        put(l_out, l_t);
        l_last := l_t;
        l_i := l_i + l_dims;
      end loop;
      if p_close and l_first is not null and l_first <> l_last then
        put(l_out, ' ' || l_first);   -- KML LinearRings must be closed
      end if;
      put(l_out, '</coordinates>');
    end coordinates;

    -- optimized rectangle: two corners (lower-left, upper-right) -> 5-point ring.
    -- Exterior rings run counter-clockwise, interior rings clockwise (KML convention).
    procedure rectangle(p_from in pls_integer, p_outer in boolean) is
      x1 varchar2(64) := fmt(l_ord(p_from));
      y1 varchar2(64) := fmt(l_ord(p_from + 1));
      x2 varchar2(64) := fmt(l_ord(p_from + l_dims));
      y2 varchar2(64) := fmt(l_ord(p_from + l_dims + 1));
    begin
      put(l_out, '<coordinates>');
      if p_outer then
        put(l_out, x1||','||y1||' '||x2||','||y1||' '||x2||','||y2||' '||x1||','||y2||' '||x1||','||y1);
      else
        put(l_out, x1||','||y1||' '||x1||','||y2||' '||x2||','||y2||' '||x2||','||y1||' '||x1||','||y1);
      end if;
      put(l_out, '</coordinates>');
    end rectangle;

    procedure close_polygon is
    begin
      if l_in_poly then
        put(l_out, '</Polygon>');
        l_in_poly := false;
      end if;
    end close_polygon;

  begin
    if l_g is null or l_g.sdo_gtype is null then
      return null;
    end if;

    ---------------------------------------------------------------- normalize
    -- arcs / compound elements / circles -> straight segments (KML has no arcs)
    if needs_densify(l_g.sdo_elem_info) then
      l_g := sdo_geom.sdo_arc_densify(l_g, p_tolerance, 'arc_tolerance=' || fmt(p_arc_tolerance));
    end if;

    -- KML is WGS84 lon/lat: transform anything else. A failure is an error --
    -- emitting projected ordinates as lon/lat would silently corrupt the map.
    if p_transform and not is_wgs84(l_g.sdo_srid) then
      begin
        l_g := sdo_cs.transform(l_g, 4326);
      exception
        when others then
          raise_application_error(-20831,
            'pck_kml_geom.to_kml: cannot transform SRID ' || l_g.sdo_srid || ' to WGS84: ' || sqlerrm);
      end;
    end if;

    l_gtype := l_g.sdo_gtype;
    l_dims  := trunc(l_gtype / 1000);
    l_lrs   := mod(trunc(l_gtype / 100), 10);
    l_ttype := mod(l_gtype, 100);
    if l_dims < 2 then                     -- pre-8i style gtype (1..7): 2D
      l_dims := 2;
    end if;
    -- altitude: 3rd ordinate unless it is the LRS measure, then the 4th (if any)
    l_zoff := case when l_dims >= 3 and l_lrs <> 3 then 2
                   when l_dims  = 4 and l_lrs  = 3 then 3
              end;

    if l_ttype in (8, 9) then
      raise_application_error(-20830, 'pck_kml_geom.to_kml: solids (gtype ' || l_gtype || ') cannot be expressed in KML');
    end if;

    l_ei  := l_g.sdo_elem_info;
    l_ord := l_g.sdo_ordinates;
    l_ntrip := case when l_ei is null then 0 else trunc(l_ei.count / 3) end;

    ---------------------------------------------------------------- count parts
    if l_g.sdo_point is not null and l_ntrip = 0 then
      l_parts := 1;
    else
      for e in 1 .. l_ntrip loop
        declare
          l_et   pls_integer := l_ei(3 * e - 1);
          l_ip   pls_integer := l_ei(3 * e);
          l_off  pls_integer := l_ei(3 * e - 2);
          l_next pls_integer := case when e < l_ntrip then l_ei(3 * e + 1) else l_ord.count + 1 end;
        begin
          if l_et = c_et_point and l_ip > 0 then
            l_parts := l_parts + trunc((l_next - l_off) / l_dims);   -- point cluster: n points
          elsif l_et = c_et_line or l_et = c_et_outer then
            l_parts := l_parts + 1;
          end if;
        end;
      end loop;
    end if;
    if l_parts = 0 then
      return null;
    end if;

    ---------------------------------------------------------------- write
    dbms_lob.createtemporary(l_out.lob, true);
    if l_parts > 1 then
      put(l_out, '<MultiGeometry>');
    end if;

    if l_g.sdo_point is not null and l_ntrip = 0 then
      put(l_out, '<Point>' || p_point_tags || '<coordinates>' || fmt(l_g.sdo_point.x) || ',' || fmt(l_g.sdo_point.y)
          || case when l_zoff = 2 and l_g.sdo_point.z is not null then ',' || fmt(l_g.sdo_point.z) end
          || '</coordinates></Point>');
    else
      for e in 1 .. l_ntrip loop
        declare
          l_off  pls_integer := l_ei(3 * e - 2);
          l_et   pls_integer := l_ei(3 * e - 1);
          l_ip   pls_integer := l_ei(3 * e);
          l_next pls_integer := case when e < l_ntrip then l_ei(3 * e + 1) else l_ord.count + 1 end;
          l_i    pls_integer;
        begin
          if l_et = c_et_point then
            close_polygon;
            if l_ip > 0 then                 -- interpretation 0 = orientation vector: skip
              l_i := l_off;
              while l_i + 1 <= l_next - 1 loop
                put(l_out, '<Point>' || p_point_tags || '<coordinates>' || tuple(l_i) || '</coordinates></Point>');
                l_i := l_i + l_dims;
              end loop;
            end if;

          elsif l_et = c_et_line then
            close_polygon;
            put(l_out, '<LineString>' || p_line_tags);
            coordinates(l_off, l_next, false);
            put(l_out, '</LineString>');

          elsif l_et = c_et_outer then
            close_polygon;
            put(l_out, '<Polygon>' || p_line_tags || '<outerBoundaryIs><LinearRing>');
            if l_ip = c_ip_rect then
              rectangle(l_off, true);
            else
              coordinates(l_off, l_next, true);
            end if;
            put(l_out, '</LinearRing></outerBoundaryIs>');
            l_in_poly := true;

          elsif l_et = c_et_inner then
            if not l_in_poly then            -- hole without a shell: tolerate as its own polygon
              put(l_out, '<Polygon>' || p_line_tags);
              l_in_poly := true;
            end if;
            put(l_out, '<innerBoundaryIs><LinearRing>');
            if l_ip = c_ip_rect then
              rectangle(l_off, false);
            else
              coordinates(l_off, l_next, true);
            end if;
            put(l_out, '</LinearRing></innerBoundaryIs>');

          else
            raise_application_error(-20830,
              'pck_kml_geom.to_kml: unsupported element type ' || l_et || '/' || l_ip || ' in gtype ' || l_gtype);
          end if;
        end;
      end loop;
      close_polygon;
    end if;

    if l_parts > 1 then
      put(l_out, '</MultiGeometry>');
    end if;
    flush(l_out);
    return l_out.lob;
  exception
    when others then
      if l_out.lob is not null and dbms_lob.istemporary(l_out.lob) = 1 then
        dbms_lob.freetemporary(l_out.lob);
      end if;
      raise;
  end to_kml;


  function from_geojson(p_geojson in clob) return sdo_geometry is
    l_obj   json_object_t;
    l_type  varchar2(40);
    l_feats json_array_t;
    l_coll  json_object_t;
    l_geoms json_array_t;
    l_el    json_element_t;
    l_f     json_object_t;
  begin
    if p_geojson is null or dbms_lob.getlength(p_geojson) = 0 then
      return null;
    end if;
    l_obj  := json_object_t.parse(p_geojson);
    l_type := l_obj.get_string('type');

    if l_type = 'Feature' then
      if l_obj.get('geometry') is null or l_obj.get('geometry').is_null then
        return null;
      end if;
      return sdo_util.from_geojson(l_obj.get_object('geometry').to_clob);

    elsif l_type = 'FeatureCollection' then
      l_feats := l_obj.get_array('features');
      l_geoms := json_array_t();
      for i in 0 .. l_feats.get_size - 1 loop
        l_el := l_feats.get(i);
        if l_el.is_object then
          l_f := treat(l_el as json_object_t);
          if l_f.get('geometry') is not null and not l_f.get('geometry').is_null then
            l_geoms.append(l_f.get('geometry'));
          end if;
        end if;
      end loop;
      if l_geoms.get_size = 0 then
        return null;
      elsif l_geoms.get_size = 1 then
        return sdo_util.from_geojson(l_geoms.get(0).to_clob);
      end if;
      l_coll := json_object_t();
      l_coll.put('type', 'GeometryCollection');
      l_coll.put('geometries', l_geoms);
      return sdo_util.from_geojson(l_coll.to_clob);

    else
      return sdo_util.from_geojson(p_geojson);   -- bare geometry
    end if;
  end from_geojson;


  function to_sdo_wgs84(p_sdo in sdo_geometry, p_geojson in clob) return sdo_geometry is
    l_g sdo_geometry;
  begin
    if p_sdo is not null then
      l_g := p_sdo;
    elsif p_geojson is not null and dbms_lob.getlength(p_geojson) > 0 then
      l_g := from_geojson(p_geojson);
    end if;
    if l_g is null then
      return null;
    end if;
    if not is_wgs84(l_g.sdo_srid) then
      l_g := sdo_cs.transform(l_g, 4326);
    end if;
    return l_g;
  exception
    when others then
      return null;   -- map helper: a bad geometry is simply not drawn
  end to_sdo_wgs84;


  function map_geojson(p_sdo in sdo_geometry, p_geojson in clob) return clob is
    l_g sdo_geometry := to_sdo_wgs84(p_sdo, p_geojson);
  begin
    if l_g is null then
      return null;
    end if;
    return sdo_util.to_geojson(l_g);
  exception
    when others then
      return null;
  end map_geojson;

end pck_kml_geom;
/
