--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_ENGINE  (generic KML/KMZ generation)
--------------------------------------------------------------------------------
-- Turns a job into a KML document (and optionally KMZ). Data sources:
--   source_type = 'ASSETS'                 render rows from KML_JOB_ASSETS
--   source_type = 'QUERY', mode 'STREAM'   run source_query and stream rows to KML
--   source_type = 'QUERY', mode 'MATERIALIZE'  run source_query into KML_JOB_ASSETS
--                                               (via the DML package), then render
--
-- One render core is shared by all paths (append_placemark / build_style_scalar /
-- switch_folder / geometry_to_kml / ext_data). The QUERY and GeoJSON ingestion
-- paths share one feature-mapping contract (geometry + reserved names + the rest
-- as ExtendedData); see also PCK_KML_JOB_ASSETS_DML.add_features_geojson.
--
-- Reads tables directly (SELECT is allowed); ALL writes go through DML packages.
-- Geometry is converted by PCK_KML_GEOM (pure PL/SQL; needs Oracle Spatial/
-- Locator but NOT the Oracle JVM -- SDO_UTIL.TO_KMLGEOMETRY is Java-based and
-- raises ORA-29538 on databases without OJVM, e.g. Oracle Database Free images).
-- Minimum Oracle 19c: SDO_UTIL.FROM_GEOJSON is a 19c feature.
--
-- SECURITY: a QUERY job's source_query is dynamic SQL executed in the dispatcher
-- with THIS schema's (definer) privileges -- the requester's context is gone.
-- Only trusted apps may enqueue QUERY jobs; parameters must be binds, not text.
--------------------------------------------------------------------------------

create or replace package pck_kml_engine
  authid definer
as
  c_pkg     constant varchar2(30)  := 'PCK_KML_ENGINE';
  gc_kml_ns constant varchar2(100) := 'http://www.opengis.net/kml/2.2';

  -- KMLeon release (semantic versioning). Single source of truth for the code;
  -- install.sql / update.sql stamp it into KML_CONFIG (KMLEON_VERSION) and the
  -- REST module exposes it under GET version. Keep in sync with /VERSION.
  gc_version constant varchar2(20) := '1.1.0';
  function version return varchar2;

  -- Convert geometry (SDO or GeoJSON) into a KML geometry fragment, optionally
  -- injecting placement tags (altitudeMode / extrude / tessellate). These affect
  -- only 3D viewers (Google Earth, Cesium, ...); 2D viewers ignore them, and
  -- altitudeMode/extrude need Z-bearing geometry to be meaningful.
  function geometry_to_kml(
    p_sdo           in sdo_geometry,
    p_geojson       in clob,
    p_altitude_mode in varchar2 default null,
    p_extrude       in varchar2 default 'N',
    p_tessellate    in varchar2 default 'N'
  ) return clob;

  -- Build the complete KML document for a job (read-only; no writes/commit).
  -- For QUERY jobs this always STREAMS (preview); materialization happens in run_job.
  function build_kml(p_job_id in number) return clob;

  -- Execute one job: build, (zip), store result, set status. Commits.
  procedure run_job(p_job_id in number);

  -- Dispatcher: process up to p_limit PENDING jobs. Called by DBMS_SCHEDULER.
  procedure process_pending(p_limit in number default 50);

  -- Helpers (public for reuse / testing).
  function escape_xml(p_text in varchar2) return varchar2;
  function rgba_to_kml(p_rgb_hex in varchar2, p_alpha in number default 255) return varchar2;

  -- UTF-8 CLOB -> BLOB. Lives here (APEX-free) so the ORDS download handler can
  -- serve KML results without depending on PCK_KML_KMZ (which needs APEX_ZIP).
  function clob_to_blob(p_clob in clob) return blob;
end pck_kml_engine;
/

create or replace package body pck_kml_engine
as

  --==============================================================================
  -- Body-level declarations
  -- (PL/SQL requires all type/variable declarations BEFORE the first subprogram.)
  --==============================================================================

  -- A folder path split into its segments (e.g. 'Europe/Germany' -> Europe, Germany).
  type t_seg_tab is table of varchar2(1000);

  -- Per-build shared-style registry: maps a <Style> XML block to its assigned id.
  type t_style_map is table of pls_integer index by varchar2(32767);
  g_styles    t_style_map;
  g_style_seq pls_integer := 0;
  -- STYLE_HIGHLIGHT_SCALE setting (read once per build): when > 0 every shared
  -- style also gets a highlight variant + a <StyleMap>; NULL = plain styles.
  g_highlight number;

  function version return varchar2 is
  begin
    return gc_version;
  end version;

  --==============================================================================
  -- Scalar helpers
  --==============================================================================

  function escape_xml(p_text in varchar2) return varchar2 is
    -- no PRAGMA UDF: this is called in tight PL/SQL loops, not from SQL
  begin
    return replace(replace(replace(replace(replace(
             p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'),
                      '"', '&quot;'), '''', '&apos;');
  end escape_xml;

  function num(p_value in number) return varchar2 is
  begin
    if p_value is null then return null; end if;
    return trim(to_char(p_value, 'TM9', 'NLS_NUMERIC_CHARACTERS=''. '''));
  end num;

  -- Coerce a scalar (incl. 'true'/'false' or 1/0) to a Y/N flag: first char Y/T/1
  -- -> Y, N/F/0 -> N, else p_default. Keeps QUERY-sourced flags valid for the Y/N
  -- columns (MATERIALIZE) and consistent when streaming.
  function yn(p_val in varchar2, p_default in varchar2) return varchar2 is
    c varchar2(1) := upper(substr(trim(p_val), 1, 1));
  begin
    return case when c in ('Y', 'T', '1') then 'Y'
                when c in ('N', 'F', '0') then 'N'
                else p_default end;
  end yn;

  function rgba_to_kml(p_rgb_hex in varchar2, p_alpha in number default 255) return varchar2 is
    pragma udf;   -- optimize use from SQL
    l_hex varchar2(8);
    l_a   varchar2(2);
  begin
    if p_rgb_hex is null then return null; end if;
    l_hex := regexp_replace(upper(p_rgb_hex), '[^0-9A-F]', '');
    if length(l_hex) != 6 then
      raise_application_error(-20801,
        'rgba_to_kml expects an RRGGBB hex color, got: ' || p_rgb_hex);
    end if;
    l_a := lpad(trim(to_char(least(greatest(nvl(p_alpha, 255), 0), 255), 'FMXX')), 2, '0');
    return lower(l_a
                 || substr(l_hex, 5, 2)   -- bb
                 || substr(l_hex, 3, 2)   -- gg
                 || substr(l_hex, 1, 2)); -- rr
  end rgba_to_kml;


  --==============================================================================
  -- Geometry
  --==============================================================================

  function geometry_to_kml(
    p_sdo           in sdo_geometry,
    p_geojson       in clob,
    p_altitude_mode in varchar2 default null,
    p_extrude       in varchar2 default 'N',
    p_tessellate    in varchar2 default 'N'
  ) return clob is
    l_geom sdo_geometry;
    l_kml  clob;
    -- canonical KML altitudeMode (case-insensitive in, exact case out); anything
    -- else is dropped with a WARN instead of emitting a dead tag into the KML.
    l_amv  varchar2(20)  := case lower(trim(p_altitude_mode))
                              when 'clamptoground'    then 'clampToGround'
                              when 'relativetoground' then 'relativeToGround'
                              when 'absolute'         then 'absolute'
                            end;
    l_ex   varchar2(40)  := case when p_extrude    = 'Y' then '<extrude>1</extrude>' end;
    l_te   varchar2(40)  := case when p_tessellate = 'Y' then '<tessellate>1</tessellate>' end;
    l_am   varchar2(120) := case when l_amv is not null
                                 then '<altitudeMode>' || l_amv || '</altitudeMode>' end;
    l_pt   varchar2(200) := l_ex || l_am;          -- Point: tessellate is not valid
    l_ln   varchar2(200) := l_ex || l_te || l_am;  -- LineString / Polygon
  begin
    if p_altitude_mode is not null and l_amv is null then
      pck_kml_log.warn(c_pkg, 'geometry_to_kml',
        'unknown altitude_mode "' || p_altitude_mode || '" ignored (use clampToGround/relativeToGround/absolute)');
    end if;

    if p_sdo is not null then
      l_geom := p_sdo;
    elsif p_geojson is not null and dbms_lob.getlength(p_geojson) > 0 then
      l_geom := pck_kml_geom.from_geojson(p_geojson);   -- geometry, Feature or FeatureCollection
    else
      return null;
    end if;

    -- Pure PL/SQL serializer (no OJVM): emits only the geometry tags plus the
    -- placement tags handed in (never its own <extrude>/<tessellate>/<altitudeMode>
    -- defaults), so the output is identical on every database release. Also
    -- transforms non-WGS84 geometries to lon/lat and densifies arcs. Inserting the
    -- tags inside the serializer avoids REPLACE() on the CLOB (each call would
    -- allocate another temporary LOB per feature).
    l_kml := pck_kml_geom.to_kml(l_geom, p_point_tags => l_pt, p_line_tags => l_ln);
    if l_kml is null then
      return null;
    end if;
    return l_kml;

  exception
    when others then
      pck_kml_log.warn(c_pkg, 'geometry_to_kml', sqlerrm);
      return null;
  end geometry_to_kml;


  function clob_to_blob(p_clob in clob) return blob is
    l_blob         blob;
    l_dest_offset  integer := 1;
    l_src_offset   integer := 1;
    l_lang_context integer := dbms_lob.default_lang_ctx;
    l_warning      integer;
  begin
    if p_clob is null then
      return null;
    end if;
    dbms_lob.createtemporary(l_blob, true);
    dbms_lob.converttoblob(
      dest_lob     => l_blob,
      src_clob     => p_clob,
      amount       => dbms_lob.lobmaxsize,
      dest_offset  => l_dest_offset,
      src_offset   => l_src_offset,
      blob_csid    => nls_charset_id('AL32UTF8'),
      lang_context => l_lang_context,
      warning      => l_warning);
    if l_warning = dbms_lob.warn_inconvertible_char then
      pck_kml_log.warn(c_pkg, 'clob_to_blob', 'inconvertible characters replaced during charset conversion');
    end if;
    return l_blob;
  exception
    when others then   -- never leak the temporary LOB if conversion fails
      if dbms_lob.istemporary(l_blob) = 1 then
        dbms_lob.freetemporary(l_blob);
      end if;
      raise;
  end clob_to_blob;


  --==============================================================================
  -- CLOB assembly primitives
  --==============================================================================

  procedure app(l_kml in out nocopy clob, p_text in varchar2) is
  begin
    if p_text is not null then
      dbms_lob.writeappend(l_kml, length(p_text), p_text);
    end if;
  end app;

  procedure appc(l_kml in out nocopy clob, p_clob in clob) is
  begin
    if p_clob is not null and dbms_lob.getlength(p_clob) > 0 then
      dbms_lob.append(l_kml, p_clob);
    end if;
  end appc;

  -- Free a per-feature temporary LOB (geometry fragment, ExtendedData block, ...)
  -- once it has been appended. Session-duration temp LOBs are not released by
  -- reassigning the variable; in a long-lived session (dispatcher, ORDS pool) a
  -- big job would otherwise pile up one temp LOB per feature in TEMP.
  procedure free_tmp(io_lob in out nocopy clob) is
  begin
    if io_lob is not null and dbms_lob.istemporary(io_lob) = 1 then
      dbms_lob.freetemporary(io_lob);
    end if;
    io_lob := null;
  exception
    when others then
      io_lob := null;
  end free_tmp;


  --==============================================================================
  -- Styling and ExtendedData
  --==============================================================================

  function build_style_scalar(
    p_icon_href    in varchar2, p_icon_scale   in number,
    p_label_color  in varchar2, p_label_scale  in number,
    p_line_color   in varchar2, p_line_width   in number,
    p_poly_color   in varchar2, p_poly_fill    in varchar2, p_poly_outline in varchar2
  ) return varchar2 is
    l_out varchar2(32767);   -- fragments (esp. an escaped icon_href) can exceed 4000
  begin
    if p_icon_href is null and p_icon_scale is null
       and p_label_color is null and p_label_scale is null
       and p_line_color is null and p_line_width is null
       and p_poly_color is null and p_poly_fill is null and p_poly_outline is null
    then
      return null;
    end if;

    l_out := '<Style>';

    if p_icon_href is not null or p_icon_scale is not null then
      l_out := l_out || '<IconStyle>';
      if p_icon_scale is not null then
        l_out := l_out || '<scale>' || num(p_icon_scale) || '</scale>';
      end if;
      if p_icon_href is not null then
        l_out := l_out || '<Icon><href>' || escape_xml(p_icon_href) || '</href></Icon>';
      end if;
      l_out := l_out || '</IconStyle>';
    end if;

    if p_label_color is not null or p_label_scale is not null then
      l_out := l_out || '<LabelStyle>';
      if p_label_color is not null then
        l_out := l_out || '<color>' || lower(p_label_color) || '</color>';
      end if;
      if p_label_scale is not null then
        l_out := l_out || '<scale>' || num(p_label_scale) || '</scale>';
      end if;
      l_out := l_out || '</LabelStyle>';
    end if;

    if p_line_color is not null or p_line_width is not null then
      l_out := l_out || '<LineStyle>';
      if p_line_color is not null then
        l_out := l_out || '<color>' || lower(p_line_color) || '</color>';
      end if;
      if p_line_width is not null then
        l_out := l_out || '<width>' || num(p_line_width) || '</width>';
      end if;
      l_out := l_out || '</LineStyle>';
    end if;

    if p_poly_color is not null or p_poly_fill is not null or p_poly_outline is not null then
      l_out := l_out || '<PolyStyle>';
      if p_poly_color is not null then
        l_out := l_out || '<color>' || lower(p_poly_color) || '</color>';
      end if;
      if p_poly_fill is not null then
        l_out := l_out || '<fill>' || case when p_poly_fill = 'Y' then '1' else '0' end || '</fill>';
      end if;
      if p_poly_outline is not null then
        l_out := l_out || '<outline>' || case when p_poly_outline = 'Y' then '1' else '0' end || '</outline>';
      end if;
      l_out := l_out || '</PolyStyle>';
    end if;

    return l_out || '</Style>';
  end build_style_scalar;


  function build_style(p_asset in kml_job_assets%rowtype) return varchar2 is
  begin
    return build_style_scalar(
             p_asset.icon_href, p_asset.icon_scale,
             p_asset.label_color, p_asset.label_scale,
             p_asset.line_color, p_asset.line_width,
             p_asset.poly_color, p_asset.poly_fill, p_asset.poly_outline);
  end build_style;


  -- Render a JSON object (already parsed) as a full <ExtendedData> block (or NULL).
  -- Best-effort and self-contained: each value is coerced to text (string or
  -- number) and the function never propagates an exception -- a single odd value
  -- must not drop the whole block or fail the caller (e.g. a streaming job).
  -- Builds a CLOB so a feature with many/large properties is not silently
  -- dropped by the 32k varchar2 limit.
  function ext_obj_to_xml(p_obj in json_object_t) return clob is
    l_keys json_key_list;
    l_out  clob;
    l_val  varchar2(32767);
  begin
    if p_obj is null then
      return null;
    end if;
    l_keys := p_obj.get_keys;
    if l_keys.count = 0 then
      return null;
    end if;
    dbms_lob.createtemporary(l_out, true);
    app(l_out, '<ExtendedData>');
    for i in 1 .. l_keys.count loop
      -- string values via get_string; fall back to numeric (NLS-safe via num)
      begin
        l_val := p_obj.get_string(l_keys(i));
      exception when others then
        l_val := null;
      end;
      if l_val is null then
        begin
          l_val := num(p_obj.get_number(l_keys(i)));
        exception when others then
          l_val := null;
        end;
      end if;
      app(l_out, '<Data name="' || escape_xml(l_keys(i)) || '">');
      app(l_out, '<value>' || escape_xml(l_val) || '</value></Data>');
    end loop;
    app(l_out, '</ExtendedData>');
    return l_out;
  exception
    when others then
      if l_out is not null and dbms_lob.istemporary(l_out) = 1 then
        dbms_lob.freetemporary(l_out);
      end if;
      return null;
  end ext_obj_to_xml;


  -- Render a JSON string as a full <ExtendedData> block (or NULL). Best-effort:
  -- malformed JSON degrades to NULL (logged at debug) rather than throwing.
  function build_extended_data(p_json in clob) return clob is
  begin
    if p_json is null or dbms_lob.getlength(p_json) = 0 then
      return null;
    end if;
    return ext_obj_to_xml(json_object_t.parse(p_json));
  exception
    when others then
      pck_kml_log.debug(c_pkg, 'build_extended_data', 'invalid ExtendedData JSON ignored: ' || sqlerrm);
      return null;
  end build_extended_data;


  procedure open_document(l_kml in out nocopy clob, p_job in kml_jobs%rowtype) is
  begin
    app(l_kml, '<?xml version="1.0" encoding="UTF-8"?>' || chr(10));
    app(l_kml, '<kml xmlns="' || gc_kml_ns || '">' || chr(10));
    app(l_kml, '<Document>');
    app(l_kml, '<name>' || escape_xml(nvl(p_job.document_name, 'KMLeon export')) || '</name>');
    if p_job.description is not null then
      app(l_kml, '<description>' || escape_xml(p_job.description) || '</description>');
    end if;
    app(l_kml, chr(10));
  end open_document;


  procedure close_document(l_kml in out nocopy clob) is
  begin
    app(l_kml, '</Document>' || chr(10));
    app(l_kml, '</kml>' || chr(10));
  end close_document;


  -- Split a '/'-separated folder path into trimmed, non-empty segments.
  -- (type t_seg_tab is declared at the top of the body.)
  function split_path(p_path in varchar2) return t_seg_tab is
    l_segs t_seg_tab := t_seg_tab();
    l_seg  varchar2(1000);
  begin
    if p_path is null then
      return l_segs;
    end if;
    for i in 1 .. regexp_count(p_path, '[^/]+') loop
      l_seg := trim(regexp_substr(p_path, '[^/]+', 1, i));
      if l_seg is not null then
        l_segs.extend;
        l_segs(l_segs.count) := l_seg;
      end if;
    end loop;
    return l_segs;
  end split_path;

  -- Adjust the open <Folder> stack to match p_path: close folders no longer on the
  -- path, open the new ones. Builds nested folders ('A/B/C'). Rows must be ordered
  -- by the folder path so groups are contiguous and parents precede their children.
  procedure switch_folder(
    l_kml    in out nocopy clob,
    io_open  in out nocopy t_seg_tab,   -- currently open segments (top = last)
    p_path   in varchar2
  ) is
    l_new    t_seg_tab := split_path(p_path);
    l_common pls_integer := 0;
  begin
    -- length of the shared prefix between the open stack and the new path
    while l_common < io_open.count
      and l_common < l_new.count
      and io_open(l_common + 1) = l_new(l_common + 1)
    loop
      l_common := l_common + 1;
    end loop;

    -- close folders below the shared prefix (deepest first)
    for i in reverse l_common + 1 .. io_open.count loop
      app(l_kml, '</Folder>' || chr(10));
    end loop;
    if io_open.count > l_common then
      io_open.trim(io_open.count - l_common);
    end if;

    -- open the new folders beyond the shared prefix
    for i in l_common + 1 .. l_new.count loop
      app(l_kml, '<Folder><name>' || escape_xml(l_new(i)) || '</name>' || chr(10));
      io_open.extend;
      io_open(io_open.count) := l_new(i);
    end loop;
  end switch_folder;

  -- Close every still-open folder (call once after the render loop).
  procedure close_folders(l_kml in out nocopy clob, io_open in out nocopy t_seg_tab) is
  begin
    for i in reverse 1 .. io_open.count loop
      app(l_kml, '</Folder>' || chr(10));
    end loop;
    io_open.delete;
  end close_folders;


  --==============================================================================
  -- Shared styles: dedupe inline <Style> blocks into <Style id> defs + styleUrls
  -- (type t_style_map + g_styles/g_style_seq are declared at the top of the body.)
  --==============================================================================

  procedure reset_styles is
  begin
    g_styles.delete;
    g_style_seq := 0;
    g_highlight := pck_kml_config_dml.get_number('STYLE_HIGHLIGHT_SCALE');
    if g_highlight is not null and g_highlight <= 0 then
      g_highlight := null;
    end if;
  end reset_styles;

  -- Register a <Style>...</Style> block and return its shared id (e.g. 'ks3').
  -- Identical style XML reuses the same id; NULL in -> NULL out.
  function register_style(p_style_xml in varchar2) return varchar2 is
  begin
    if p_style_xml is null then
      return null;
    end if;
    if not g_styles.exists(p_style_xml) then
      g_style_seq := g_style_seq + 1;
      g_styles(p_style_xml) := g_style_seq;
    end if;
    return 'ks' || g_styles(p_style_xml);
  end register_style;

  -- The styleUrl a placemark references for a registered style id: the plain
  -- style, or its <StyleMap> when highlight styles are enabled.
  function style_ref(p_id in varchar2) return varchar2 is
  begin
    return '#' || p_id || case when g_highlight is not null then 'm' end;
  end style_ref;

  -- Scale every <scale>/<width> inside a <Style> block by p_factor (icon scale,
  -- label scale, line width); sub-styles without an explicit value get the factor
  -- itself (their implicit default is 1). The result is the "highlight" variant.
  function highlight_style(p_style_xml in varchar2, p_factor in number) return varchar2 is
    l varchar2(32767) := p_style_xml;
    l_f varchar2(40) := num(p_factor);
    l_pos pls_integer := 1;
    l_m varchar2(200);
    l_v number;
  begin
    -- explicit <scale>v</scale> / <width>v</width>
    loop
      l_m := regexp_substr(l, '<(scale|width)>[^<]+</\1>', l_pos);
      exit when l_m is null;
      l_pos := regexp_instr(l, '<(scale|width)>[^<]+</\1>', l_pos);
      l_v := to_number(regexp_substr(l_m, '>([^<]+)<', 1, 1, null, 1),
                       '999999999999999999.999999999999', 'NLS_NUMERIC_CHARACTERS=''. ''');
      l := substr(l, 1, l_pos - 1)
           || regexp_replace(l_m, '>[^<]+<', '>' || num(l_v * p_factor) || '<')
           || substr(l, l_pos + length(l_m));
      l_pos := l_pos + 1;
    end loop;
    -- implicit defaults
    if instr(l, '<IconStyle>') > 0 and not regexp_like(l, '<IconStyle>(<[^/][^>]*>[^<]*</[^>]+>)*<scale>') then
      l := replace(l, '<IconStyle>', '<IconStyle><scale>' || l_f || '</scale>');
    end if;
    if instr(l, '<LineStyle>') > 0 and not regexp_like(l, '<LineStyle>(<[^/][^>]*>[^<]*</[^>]+>)*<width>') then
      l := replace(l, '<LineStyle>', '<LineStyle><width>' || l_f || '</width>');
    end if;
    if instr(l, '<IconStyle>') = 0 and instr(l, '<LineStyle>') = 0 and instr(l, '<LabelStyle>') = 0 then
      -- polygon-only style: make the highlight visible through a thicker outline
      l := replace(l, '</Style>', '<LineStyle><width>' || l_f || '</width></LineStyle></Style>');
    end if;
    return l;
  exception
    when others then
      return p_style_xml;   -- never break a build over a highlight cosmetic
  end highlight_style;

  -- Emit every registered style as a <Style id="ks#"> definition (Document header);
  -- with STYLE_HIGHLIGHT_SCALE also "ks#h" (highlight) and the <StyleMap id="ks#m">.
  procedure emit_styles(l_kml in out nocopy clob) is
    l_key varchar2(32767);
    l_id  varchar2(30);
  begin
    l_key := g_styles.first;
    while l_key is not null loop
      l_id := 'ks' || g_styles(l_key);
      -- the key always starts with '<Style>'; rewrite only that opening tag
      app(l_kml, '<Style id="' || l_id || '">' || substr(l_key, length('<Style>') + 1) || chr(10));
      if g_highlight is not null then
        app(l_kml, '<Style id="' || l_id || 'h">'
                   || substr(highlight_style(l_key, g_highlight), length('<Style>') + 1) || chr(10));
        app(l_kml, '<StyleMap id="' || l_id || 'm">'
                   || '<Pair><key>normal</key><styleUrl>#' || l_id || '</styleUrl></Pair>'
                   || '<Pair><key>highlight</key><styleUrl>#' || l_id || 'h</styleUrl></Pair>'
                   || '</StyleMap>' || chr(10));
      end if;
      l_key := g_styles.next(l_key);
    end loop;
  end emit_styles;


  procedure append_placemark(
    l_kml         in out nocopy clob,
    p_name        in varchar2,
    p_description in clob,
    p_ext_xml     in clob,
    p_style       in varchar2,
    p_geom        in clob,
    p_visibility  in varchar2
  ) is
    l_desc clob;
  begin
    app(l_kml, '<Placemark>');
    -- KML 2.2 schema order: <name> before <visibility>.
    if p_name is not null then
      app(l_kml, '<name>' || escape_xml(p_name) || '</name>');
    end if;
    if p_visibility = 'N' then
      app(l_kml, '<visibility>0</visibility>');
    end if;
    if p_description is not null and dbms_lob.getlength(p_description) > 0 then
      l_desc := replace(p_description, ']]>', ']]]]><![CDATA[>');
      app(l_kml, '<description><![CDATA[');
      appc(l_kml, l_desc);
      app(l_kml, ']]></description>');
    end if;
    if p_style is not null then
      app(l_kml, '<styleUrl>' || style_ref(register_style(p_style)) || '</styleUrl>');
    end if;
    appc(l_kml, p_ext_xml);
    appc(l_kml, p_geom);
    app(l_kml, '</Placemark>' || chr(10));
  end append_placemark;


  --==============================================================================
  -- Source: ASSETS
  --==============================================================================

  procedure render_from_assets(l_kml in out nocopy clob, p_job_id in number, p_count out number) is
    l_open t_seg_tab := t_seg_tab();   -- open folder path stack
    l_geom clob;
    l_ext  clob;
  begin
    p_count := 0;
    for r in (
      select *
        from kml_job_assets
       where job_id = p_job_id
       order by case when folder_name is null then 0 else 1 end,
                folder_name, display_order, asset_id
    ) loop
      l_geom := geometry_to_kml(r.geometry_sdo, r.geometry_geojson,
                                r.altitude_mode, r.extrude, r.tessellate);
      if l_geom is not null and dbms_lob.getlength(l_geom) > 0 then
        switch_folder(l_kml, l_open, r.folder_name);
        l_ext := build_extended_data(r.extended_data);
        append_placemark(l_kml, r.name, r.description, l_ext,
                         build_style(r), l_geom, r.visibility);
        p_count := p_count + 1;
        free_tmp(l_ext);
      else
        pck_kml_log.warn(c_pkg, 'render_from_assets',
                         'asset ' || r.asset_id || ' skipped (no usable geometry)', p_job_id);
      end if;
      free_tmp(l_geom);
    end loop;
    close_folders(l_kml, l_open);
  end render_from_assets;


  --==============================================================================
  -- Source: QUERY  (DBMS_SQL; one producer, two sinks)
  --   p_mode = 'STREAM'       append placemarks to l_kml
  --   p_mode = 'MATERIALIZE'  insert rows into KML_JOB_ASSETS (l_kml unused)
  --==============================================================================

  procedure run_query(
    p_job   in kml_jobs%rowtype,
    p_mode  in varchar2,
    l_kml   in out nocopy clob,
    p_count out number
  ) is
    l_c      integer;
    l_cols   number;
    l_desc_t dbms_sql.desc_tab3;
    l_exec   integer;
    l_open   t_seg_tab := t_seg_tab();   -- open folder path stack (STREAM only)

    type t_meta is record (role varchar2(20), fetch_kind varchar2(5), alias varchar2(128));
    type t_meta_tab is table of t_meta index by pls_integer;
    l_meta t_meta_tab;

    -- holders reused per column fetch
    l_vc   varchar2(4000);
    l_num  number;
    l_dat  date;
    l_ts   timestamp;
    l_tstz timestamp with time zone;
    l_clob clob;
    l_sdo  sdo_geometry;

    -- per-row accumulators
    l_name        varchar2(4000);  l_descr        clob;
    l_folder      varchar2(1000);  l_vis          varchar2(1);
    l_alt         varchar2(20);    l_extr         varchar2(1);  l_tess varchar2(1);
    l_icon_href   varchar2(1000);  l_icon_scale   number;
    l_label_color varchar2(8);     l_label_scale  number;
    l_line_color  varchar2(8);     l_line_width   number;
    l_poly_color  varchar2(8);     l_poly_fill    varchar2(1);  l_poly_outline varchar2(1);
    l_geom_sdo    sdo_geometry;    l_geom_geojson clob;          l_geom_kml clob;  l_geom clob;
    l_ext_obj     json_object_t;   l_ext_text     clob;          l_ext_xml clob;
    l_dummy       number;

    l_bobj  json_object_t;
    l_bkeys json_key_list;

    function role_of(p_alias in varchar2) return varchar2 is
      a varchar2(128) := upper(p_alias);
    begin
      return case a
        when 'GEOMETRY'         then 'GEOM_SDO'
        when 'GEOMETRY_SDO'     then 'GEOM_SDO'
        when 'GEOMETRY_GEOJSON' then 'GEOM_GEOJSON'
        when 'GEOMETRY_KML'     then 'GEOM_KML'
        when 'NAME'             then 'NAME'
        when 'DESCRIPTION'      then 'DESCRIPTION'
        when 'FOLDER_NAME'      then 'FOLDER_NAME'
        when 'DISPLAY_ORDER'    then 'IGNORE'
        when 'VISIBILITY'       then 'VISIBILITY'
        when 'ALTITUDE_MODE'    then 'ALTITUDE_MODE'
        when 'EXTRUDE'          then 'EXTRUDE'
        when 'TESSELLATE'       then 'TESSELLATE'
        when 'ICON_HREF'        then 'ICON_HREF'
        when 'ICON_SCALE'       then 'ICON_SCALE'
        when 'LABEL_COLOR'      then 'LABEL_COLOR'
        when 'LABEL_SCALE'      then 'LABEL_SCALE'
        when 'LINE_COLOR'       then 'LINE_COLOR'
        when 'LINE_WIDTH'       then 'LINE_WIDTH'
        when 'POLY_COLOR'       then 'POLY_COLOR'
        when 'POLY_FILL'        then 'POLY_FILL'
        when 'POLY_OUTLINE'     then 'POLY_OUTLINE'
        when 'EXTENDED_DATA'    then 'EXTENDED_DATA'
        else 'EXT_PROP'
      end;
    end role_of;

    -- read the holder (set by the preceding column_value) as text/number/clob
    function as_vc(p_i in pls_integer) return varchar2 is
    begin
      return case l_meta(p_i).fetch_kind
               when 'VC'   then l_vc
               when 'NUM'  then num(l_num)
               when 'DATE' then to_char(l_dat, 'YYYY-MM-DD"T"HH24:MI:SS')
               when 'TS'   then to_char(l_ts,   'YYYY-MM-DD"T"HH24:MI:SS.FF3')
               when 'TSTZ' then to_char(l_tstz, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZH:TZM')
               when 'CLOB' then dbms_lob.substr(l_clob, 4000, 1)
               else null
             end;
    end as_vc;

    function as_num(p_i in pls_integer) return number is
    begin
      return case l_meta(p_i).fetch_kind
               when 'NUM' then l_num
               when 'VC'  then to_number(l_vc default null on conversion error)
               else null
             end;
    end as_num;

    function as_clob(p_i in pls_integer) return clob is
    begin
      -- CLOB columns pass through; anything else is rendered to text then promoted
      return case when l_meta(p_i).fetch_kind = 'CLOB' then l_clob
                  else to_clob(as_vc(p_i))
             end;
    end as_clob;

  begin
    p_count := 0;
    l_c := dbms_sql.open_cursor;
    dbms_sql.parse(l_c, p_job.source_query, dbms_sql.native);

    -- bind values from source_binds JSON (best effort; absent binds are skipped)
    if p_job.source_binds is not null and dbms_lob.getlength(p_job.source_binds) > 0 then
      begin
        l_bobj  := json_object_t.parse(p_job.source_binds);
        l_bkeys := l_bobj.get_keys;
        for i in 1 .. l_bkeys.count loop
          begin
            -- bind by JSON type: NUMBER as number, BOOLEAN as 1/0, NULL as NULL text,
            -- everything else as text (get_string raises on non-string scalars)
            if l_bobj.get(l_bkeys(i)).is_number then
              dbms_sql.bind_variable(l_c, ':' || l_bkeys(i), l_bobj.get_number(l_bkeys(i)));
            elsif l_bobj.get(l_bkeys(i)).is_true then
              dbms_sql.bind_variable(l_c, ':' || l_bkeys(i), '1');
            elsif l_bobj.get(l_bkeys(i)).is_false then
              dbms_sql.bind_variable(l_c, ':' || l_bkeys(i), '0');
            elsif l_bobj.get(l_bkeys(i)).is_null then
              dbms_sql.bind_variable(l_c, ':' || l_bkeys(i), cast(null as varchar2));
            else
              dbms_sql.bind_variable(l_c, ':' || l_bkeys(i), l_bobj.get_string(l_bkeys(i)));
            end if;
          exception
            when others then
              pck_kml_log.debug(c_pkg, 'run_query', 'bind skipped: ' || l_bkeys(i), p_job.job_id);
          end;
        end loop;
      exception
        when others then
          pck_kml_log.warn(c_pkg, 'run_query', 'source_binds ignored (invalid JSON)', p_job.job_id);
      end;
    end if;

    -- describe columns and define each by role / type
    dbms_sql.describe_columns3(l_c, l_cols, l_desc_t);
    for i in 1 .. l_cols loop
      declare
        l_m t_meta;
      begin
        l_m.alias := l_desc_t(i).col_name;
        l_m.role  := role_of(l_desc_t(i).col_name);
        begin
          if l_m.role = 'GEOM_SDO' then
            l_m.fetch_kind := 'SDO';  dbms_sql.define_column(l_c, i, l_sdo);
          elsif l_desc_t(i).col_type = 112 then           -- CLOB
            l_m.fetch_kind := 'CLOB'; dbms_sql.define_column(l_c, i, l_clob);
          elsif l_desc_t(i).col_type = 2 then             -- NUMBER
            l_m.fetch_kind := 'NUM';  dbms_sql.define_column(l_c, i, l_num);
          elsif l_desc_t(i).col_type = 12 then            -- DATE
            l_m.fetch_kind := 'DATE'; dbms_sql.define_column(l_c, i, l_dat);
          elsif l_desc_t(i).col_type = 180 then           -- TIMESTAMP
            l_m.fetch_kind := 'TS';   dbms_sql.define_column(l_c, i, l_ts);
          elsif l_desc_t(i).col_type = 181 then           -- TIMESTAMP WITH TIME ZONE
            l_m.fetch_kind := 'TSTZ'; dbms_sql.define_column(l_c, i, l_tstz);
          elsif l_desc_t(i).col_type in (1, 96) then      -- VARCHAR2 / CHAR
            l_m.fetch_kind := 'VC';   dbms_sql.define_column(l_c, i, l_vc, 4000);
          else
            l_m.fetch_kind := 'SKIP';
            pck_kml_log.warn(c_pkg, 'run_query',
              'column "' || l_desc_t(i).col_name || '" type ' || l_desc_t(i).col_type
              || ' unsupported; CAST to varchar2/number/date/timestamp in the query', p_job.job_id);
          end if;
        exception
          when others then   -- e.g. GEOMETRY aliased onto a non-SDO column: skip it, don't fail the job
            l_m.fetch_kind := 'SKIP';
            pck_kml_log.warn(c_pkg, 'run_query',
              'column "' || l_desc_t(i).col_name || '" define failed; skipped: ' || sqlerrm, p_job.job_id);
        end;
        l_meta(i) := l_m;
      end;
    end loop;

    l_exec := dbms_sql.execute(l_c);

    while dbms_sql.fetch_rows(l_c) > 0 loop
      -- reset per-row state
      l_name := null; l_descr := null; l_folder := null; l_vis := 'Y';
      l_alt := null; l_extr := 'N'; l_tess := 'N';
      l_icon_href := null; l_icon_scale := null; l_label_color := null; l_label_scale := null;
      l_line_color := null; l_line_width := null;
      l_poly_color := null; l_poly_fill := null; l_poly_outline := null;
      l_geom_sdo := null; l_geom_geojson := null; l_geom_kml := null; l_geom := null;
      l_ext_obj := json_object_t();

      for i in 1 .. l_cols loop
        if l_meta(i).fetch_kind != 'SKIP' then
          case l_meta(i).fetch_kind
            when 'SDO'  then dbms_sql.column_value(l_c, i, l_sdo);
            when 'CLOB' then dbms_sql.column_value(l_c, i, l_clob);
            when 'NUM'  then dbms_sql.column_value(l_c, i, l_num);
            when 'DATE' then dbms_sql.column_value(l_c, i, l_dat);
            when 'TS'   then dbms_sql.column_value(l_c, i, l_ts);
            when 'TSTZ' then dbms_sql.column_value(l_c, i, l_tstz);
            else             dbms_sql.column_value(l_c, i, l_vc);
          end case;

          case l_meta(i).role
            when 'GEOM_SDO'      then l_geom_sdo     := l_sdo;
            when 'GEOM_GEOJSON'  then l_geom_geojson := as_clob(i);
            when 'GEOM_KML'      then l_geom_kml     := as_clob(i);
            when 'NAME'          then l_name         := as_vc(i);
            when 'DESCRIPTION'   then l_descr        := as_clob(i);
            when 'FOLDER_NAME'   then l_folder       := substr(as_vc(i), 1, 1000);
            when 'VISIBILITY'    then l_vis          := yn(as_vc(i), 'Y');
            when 'ALTITUDE_MODE' then l_alt          := substr(as_vc(i), 1, 20);
            when 'EXTRUDE'       then l_extr         := yn(as_vc(i), 'N');
            when 'TESSELLATE'    then l_tess         := yn(as_vc(i), 'N');
            when 'ICON_HREF'     then l_icon_href    := substr(as_vc(i), 1, 1000);
            when 'ICON_SCALE'    then l_icon_scale   := as_num(i);
            when 'LABEL_COLOR'   then l_label_color  := substr(as_vc(i), 1, 8);
            when 'LABEL_SCALE'   then l_label_scale  := as_num(i);
            when 'LINE_COLOR'    then l_line_color   := substr(as_vc(i), 1, 8);
            when 'LINE_WIDTH'    then l_line_width   := as_num(i);
            when 'POLY_COLOR'    then l_poly_color   := substr(as_vc(i), 1, 8);
            when 'POLY_FILL'     then l_poly_fill    := yn(as_vc(i), 'Y');
            when 'POLY_OUTLINE'  then l_poly_outline := yn(as_vc(i), 'Y');
            when 'EXTENDED_DATA' then
              begin
                declare
                  l_e  json_object_t := json_object_t.parse(as_clob(i));
                  l_ek json_key_list := l_e.get_keys;
                begin
                  for j in 1 .. l_ek.count loop
                    l_ext_obj.put(l_ek(j), l_e.get(l_ek(j)));
                  end loop;
                end;
              exception when others then
                pck_kml_log.warn(c_pkg, 'run_query',
                  'EXTENDED_DATA column ignored (invalid JSON): ' || sqlerrm, p_job.job_id);
              end;
            when 'EXT_PROP' then
              if as_vc(i) is not null then
                l_ext_obj.put(l_meta(i).alias, as_vc(i));
              end if;
            else null;  -- IGNORE
          end case;
        end if;
      end loop;

      if p_mode = 'MATERIALIZE' then
        if l_geom_sdo is not null
           or (l_geom_geojson is not null and dbms_lob.getlength(l_geom_geojson) > 0)
        then
          l_ext_text := case when l_ext_obj.get_size > 0 then l_ext_obj.to_clob end;
          l_dummy := pck_kml_job_assets_dml.ins(
            p_job_id           => p_job.job_id,
            p_geometry_sdo     => l_geom_sdo,
            p_geometry_geojson => l_geom_geojson,
            p_name             => substr(l_name, 1, 400),
            p_description      => l_descr,
            p_extended_data    => l_ext_text,
            p_folder_name      => l_folder,
            p_altitude_mode    => l_alt,
            p_extrude          => l_extr,
            p_tessellate       => l_tess,
            p_icon_href        => l_icon_href,
            p_icon_scale       => l_icon_scale,
            p_label_color      => l_label_color,
            p_label_scale      => l_label_scale,
            p_line_color       => l_line_color,
            p_line_width       => l_line_width,
            p_poly_color       => l_poly_color,
            p_poly_fill        => l_poly_fill,
            p_poly_outline     => l_poly_outline,
            p_visibility       => l_vis);
          p_count := p_count + 1;
        else
          pck_kml_log.warn(c_pkg, 'run_query',
            'MATERIALIZE row skipped (needs SDO/GeoJSON; GEOMETRY_KML not storable)', p_job.job_id);
        end if;

      else  -- STREAM
        if l_geom_kml is not null and dbms_lob.getlength(l_geom_kml) > 0 then
          l_geom := l_geom_kml;   -- passthrough: caller-supplied KML is left as-is
        elsif l_geom_sdo is not null then
          l_geom := geometry_to_kml(l_geom_sdo, null, l_alt, l_extr, l_tess);
        elsif l_geom_geojson is not null and dbms_lob.getlength(l_geom_geojson) > 0 then
          l_geom := geometry_to_kml(null, l_geom_geojson, l_alt, l_extr, l_tess);
        end if;

        if l_geom is not null and dbms_lob.getlength(l_geom) > 0 then
          l_ext_xml := ext_obj_to_xml(l_ext_obj);   -- build directly; no JSON re-parse
          switch_folder(l_kml, l_open, l_folder);
          append_placemark(l_kml, l_name, l_descr, l_ext_xml,
                           build_style_scalar(l_icon_href, l_icon_scale, l_label_color, l_label_scale,
                                              l_line_color, l_line_width,
                                              l_poly_color, l_poly_fill, l_poly_outline),
                           l_geom, l_vis);
          p_count := p_count + 1;
          free_tmp(l_ext_xml);
        else
          pck_kml_log.warn(c_pkg, 'run_query', 'STREAM row skipped (no usable geometry)', p_job.job_id);
        end if;
        -- release this row's temporary LOBs (geometry fragment, to_clob()-promoted
        -- values, DBMS_SQL CLOB column values are all temporaries)
        free_tmp(l_geom);          -- also covers the GEOMETRY_KML passthrough (same locator)
        l_geom_kml := null;
        free_tmp(l_geom_geojson);
        free_tmp(l_descr);
      end if;
    end loop;

    if p_mode != 'MATERIALIZE' then
      close_folders(l_kml, l_open);
    end if;
    dbms_sql.close_cursor(l_c);
  exception
    when others then
      if dbms_sql.is_open(l_c) then
        dbms_sql.close_cursor(l_c);
      end if;
      raise;
  end run_query;


  --==============================================================================
  -- Document assembly + execution
  --==============================================================================

  -- Assemble the final document: header -> shared <Style> defs -> body -> footer.
  -- The body (folders + placemarks) is rendered first into a buffer so the styles
  -- it registers can be emitted up front; placemarks reference them via styleUrl.
  function assemble(p_job in kml_jobs%rowtype, p_body in out nocopy clob) return clob is
    l_kml clob;
  begin
    dbms_lob.createtemporary(l_kml, true);
    open_document(l_kml, p_job);
    emit_styles(l_kml);
    appc(l_kml, p_body);
    close_document(l_kml);
    dbms_lob.freetemporary(p_body);
    p_body := null;   -- so callers' error handlers can never double-free it
    return l_kml;
  end assemble;


  function build_assets_document(p_job_id in number, p_count out number) return clob is
    l_body clob;
    l_job  kml_jobs%rowtype;
  begin
    reset_styles;
    l_job := pck_kml_jobs_dml.get(p_job_id);
    dbms_lob.createtemporary(l_body, true);
    render_from_assets(l_body, p_job_id, p_count);
    return assemble(l_job, l_body);   -- assemble frees l_body on success
  exception
    when others then   -- render failed before assemble could free the body buffer
      if l_body is not null and dbms_lob.istemporary(l_body) = 1 then
        dbms_lob.freetemporary(l_body);
      end if;
      raise;
  end build_assets_document;


  function build_query_document(p_job in kml_jobs%rowtype, p_count out number) return clob is
    l_body clob;
  begin
    reset_styles;
    dbms_lob.createtemporary(l_body, true);
    run_query(p_job, 'STREAM', l_body, p_count);
    return assemble(p_job, l_body);   -- assemble frees l_body on success
  exception
    when others then   -- run_query failed before assemble could free the body buffer
      if l_body is not null and dbms_lob.istemporary(l_body) = 1 then
        dbms_lob.freetemporary(l_body);
      end if;
      raise;
  end build_query_document;


  function build_kml(p_job_id in number) return clob is
    l_job   kml_jobs%rowtype;
    l_count number;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);
    if upper(l_job.source_type) = 'QUERY' then
      return build_query_document(l_job, l_count);     -- preview = stream, no writes
    else
      return build_assets_document(p_job_id, l_count);
    end if;
  end build_kml;


  procedure run_job(p_job_id in number) is
    l_job    kml_jobs%rowtype;
    l_kml    clob;
    l_kmz    blob;
    l_count  number;
    l_mcount number;
    l_void   clob;
  begin
    -- Atomically claim the job (-> RUNNING) unless another session already has it
    -- RUNNING; prevents concurrent double-processing. A deliberate re-run of a
    -- COMPLETED/FAILED/CANCELLED job is still allowed (its status is not RUNNING).
    if pck_kml_jobs_dml.claim(p_job_id) = 0 then
      l_job := pck_kml_jobs_dml.get(p_job_id);   -- existence check (raises -20813 if not found)
      pck_kml_log.warn(c_pkg, 'run_job', 'job already RUNNING; duplicate run skipped', p_job_id);
      return;
    end if;
    l_job := pck_kml_jobs_dml.get(p_job_id);

    -- Re-running an ASSETS job whose inputs were auto-cleaned after success would
    -- silently overwrite the stored result with an empty document -- fail clearly
    -- instead. First runs are unaffected (finished_at is null); set_failed keeps
    -- result_kml/result_kmz, so the last good result survives on the row.
    if upper(l_job.source_type) = 'ASSETS' and l_job.finished_at is not null then
      declare
        l_n pls_integer;
      begin
        select count(*) into l_n from kml_job_assets where job_id = p_job_id and rownum = 1;
        if l_n = 0 then
          raise_application_error(-20816,
            'ASSETS job ' || p_job_id || ' has no input rows (assets were cleaned up '
            || 'after the last run); a re-run cannot produce a document.');
        end if;
      end;
    end if;

    if upper(l_job.source_type) = 'QUERY' and upper(l_job.source_mode) = 'MATERIALIZE' then
      pck_kml_job_assets_dml.del_by_job(p_job_id);          -- idempotent re-run
      dbms_lob.createtemporary(l_void, true);                -- unused sink, but pass a valid LOB
      run_query(l_job, 'MATERIALIZE', l_void, l_mcount);     -- writes assets
      if l_void is not null and dbms_lob.istemporary(l_void) = 1 then  -- free the sink (not auto-freed)
        dbms_lob.freetemporary(l_void);
      end if;
      l_kml := build_assets_document(p_job_id, l_count);     -- render the materialized assets
    elsif upper(l_job.source_type) = 'QUERY' then
      l_kml := build_query_document(l_job, l_count);
    else
      l_kml := build_assets_document(p_job_id, l_count);
    end if;

    if nvl(l_count, 0) = 0 then
      pck_kml_log.warn(c_pkg, 'run_job',
        'job completed with 0 features -- empty document (all rows skipped or no input)', p_job_id);
    end if;

    if upper(l_job.output_format) = 'KMZ' then
      l_kmz := pck_kml_kmz.zip_kml(l_kml, 'doc.kml');
      pck_kml_jobs_dml.set_completed(p_job_id, p_kmz => l_kmz,
                                     p_size => dbms_lob.getlength(l_kmz), p_count => l_count);
    else
      pck_kml_jobs_dml.set_completed(p_job_id, p_kml => l_kml,
                                     p_size => dbms_lob.getlength(l_kml), p_count => l_count);
    end if;

    commit;

    -- free the result temp LOBs now they are persisted on the job row. Matters in
    -- long-lived sessions (the dispatcher / a one-shot background run) where the
    -- temporary tablespace would otherwise grow by one result per job.
    if l_kml is not null and dbms_lob.istemporary(l_kml) = 1 then
      dbms_lob.freetemporary(l_kml);
    end if;
    if l_kmz is not null and dbms_lob.istemporary(l_kmz) = 1 then
      dbms_lob.freetemporary(l_kmz);
    end if;

    -- best-effort: free the input assets after a successful build (configurable,
    -- default ON). Separate transaction so a cleanup error never affects the
    -- already-committed COMPLETED job. del_by_job is a no-op when there are none.
    begin
      if pck_kml_config_dml.get_boolean('DELETE_ASSETS_AFTER_SUCCESS', true) then
        pck_kml_job_assets_dml.del_by_job(p_job_id);
        commit;
      end if;
    exception when others then
      rollback;
      pck_kml_log.warn(c_pkg, 'run_job', 'asset cleanup after success skipped: ' || sqlerrm, p_job_id);
    end;

    -- best-effort completion notification (must never affect the committed job)
    begin
      pck_kml_notify.notify(p_job_id, 'COMPLETED');
    exception when others then
      pck_kml_log.error(c_pkg, 'run_job', 'notify(COMPLETED) failed: ' || sqlerrm, p_job_id);
    end;
  exception
    when others then
      -- free any temp LOBs before failing (MATERIALIZE sink + partial result)
      if l_void is not null and dbms_lob.istemporary(l_void) = 1 then
        dbms_lob.freetemporary(l_void);
      end if;
      if l_kml is not null and dbms_lob.istemporary(l_kml) = 1 then
        dbms_lob.freetemporary(l_kml);
      end if;
      if l_kmz is not null and dbms_lob.istemporary(l_kmz) = 1 then
        dbms_lob.freetemporary(l_kmz);
      end if;
      rollback;
      pck_kml_jobs_dml.set_failed(p_job_id,
        sqlerrm || chr(10) || dbms_utility.format_error_backtrace);
      commit;
      begin
        pck_kml_notify.notify(p_job_id, 'FAILED');
      exception when others then
        pck_kml_log.error(c_pkg, 'run_job', 'notify(FAILED) failed: ' || sqlerrm, p_job_id);
      end;
  end run_job;


  procedure process_pending(p_limit in number default 50) is
  begin
    for r in (
      select job_id
        from kml_jobs
       where status = 'PENDING'
       order by priority, created_at
       fetch first p_limit rows only
    ) loop
      run_job(r.job_id);
    end loop;
  end process_pending;

end pck_kml_engine;
/
