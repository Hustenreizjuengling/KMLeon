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
-- Geometry is converted natively via SDO_UTIL (requires Oracle Spatial/Locator).
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

  -- Convert geometry (SDO or GeoJSON) into a KML geometry fragment.
  function geometry_to_kml(p_sdo in sdo_geometry, p_geojson in clob) return clob;

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
end pck_kml_engine;
/

create or replace package body pck_kml_engine
as

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

  function geometry_to_kml(p_sdo in sdo_geometry, p_geojson in clob) return clob is
    l_geom sdo_geometry;
  begin
    if p_sdo is not null then
      l_geom := p_sdo;
    elsif p_geojson is not null and dbms_lob.getlength(p_geojson) > 0 then
      l_geom := sdo_util.from_geojson(p_geojson);
    else
      return null;
    end if;
    return sdo_util.to_kmlgeometry(l_geom);
  exception
    when others then
      pck_kml_log.warn(c_pkg, 'geometry_to_kml', sqlerrm);
      return null;
  end geometry_to_kml;


  --==============================================================================
  -- Styling and ExtendedData
  --==============================================================================

  function build_style_scalar(
    p_icon_href    in varchar2, p_icon_scale   in number,
    p_label_color  in varchar2, p_label_scale  in number,
    p_line_color   in varchar2, p_line_width   in number,
    p_poly_color   in varchar2, p_poly_fill    in varchar2, p_poly_outline in varchar2
  ) return varchar2 is
    l_out varchar2(4000);
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


  -- Render a JSON object as a full <ExtendedData> block (or NULL). Best-effort.
  function build_extended_data(p_json in clob) return varchar2 is
    l_obj  json_object_t;
    l_keys json_key_list;
    l_out  varchar2(32767);
  begin
    if p_json is null or dbms_lob.getlength(p_json) = 0 then
      return null;
    end if;
    l_obj  := json_object_t.parse(p_json);
    l_keys := l_obj.get_keys;
    if l_keys.count = 0 then
      return null;
    end if;
    l_out := '<ExtendedData>';
    for i in 1 .. l_keys.count loop
      l_out := l_out
            || '<Data name="' || escape_xml(l_keys(i)) || '">'
            || '<value>' || escape_xml(l_obj.get_string(l_keys(i))) || '</value></Data>';
    end loop;
    return l_out || '</ExtendedData>';
  exception
    when others then
      return null;
  end build_extended_data;


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


  -- Open/close <Folder> wrappers as the folder value changes between rows.
  -- Rows must already be ordered by folder for grouping to be contiguous.
  procedure switch_folder(
    l_kml    in out nocopy clob,
    io_open  in out varchar2,
    io_cur   in out varchar2,
    p_folder in varchar2
  ) is
  begin
    if nvl(p_folder, '##NULL##') <> nvl(io_cur, '##NULL##') then
      if io_open = 'Y' then
        app(l_kml, '</Folder>' || chr(10));
        io_open := 'N';
      end if;
      if p_folder is not null then
        app(l_kml, '<Folder><name>' || escape_xml(p_folder) || '</name>' || chr(10));
        io_open := 'Y';
      end if;
      io_cur := p_folder;
    end if;
  end switch_folder;


  procedure append_placemark(
    l_kml         in out nocopy clob,
    p_name        in varchar2,
    p_description in clob,
    p_ext_xml     in varchar2,
    p_style       in varchar2,
    p_geom        in clob,
    p_visibility  in varchar2
  ) is
    l_desc clob;
  begin
    app(l_kml, '<Placemark>');
    if p_visibility = 'N' then
      app(l_kml, '<visibility>0</visibility>');
    end if;
    if p_name is not null then
      app(l_kml, '<name>' || escape_xml(p_name) || '</name>');
    end if;
    if p_description is not null and dbms_lob.getlength(p_description) > 0 then
      l_desc := replace(p_description, ']]>', ']]]]><![CDATA[>');
      app(l_kml, '<description><![CDATA[');
      appc(l_kml, l_desc);
      app(l_kml, ']]></description>');
    end if;
    app(l_kml, p_style);
    app(l_kml, p_ext_xml);
    appc(l_kml, p_geom);
    app(l_kml, '</Placemark>' || chr(10));
  end append_placemark;


  --==============================================================================
  -- Source: ASSETS
  --==============================================================================

  procedure render_from_assets(l_kml in out nocopy clob, p_job_id in number, p_count out number) is
    l_open varchar2(1)    := 'N';
    l_cur  varchar2(1000) := '##INIT##';
    l_geom clob;
  begin
    p_count := 0;
    for r in (
      select *
        from kml_job_assets
       where job_id = p_job_id
       order by case when folder_name is null then 0 else 1 end,
                folder_name, display_order, asset_id
    ) loop
      l_geom := geometry_to_kml(r.geometry_sdo, r.geometry_geojson);
      if l_geom is not null and dbms_lob.getlength(l_geom) > 0 then
        switch_folder(l_kml, l_open, l_cur, r.folder_name);
        append_placemark(l_kml, r.name, r.description, build_extended_data(r.extended_data),
                         build_style(r), l_geom, r.visibility);
        p_count := p_count + 1;
      else
        pck_kml_log.warn(c_pkg, 'render_from_assets',
                         'asset ' || r.asset_id || ' skipped (no usable geometry)', p_job_id);
      end if;
    end loop;
    if l_open = 'Y' then
      app(l_kml, '</Folder>' || chr(10));
    end if;
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
    l_open   varchar2(1)    := 'N';
    l_curf   varchar2(1000) := '##INIT##';

    type t_meta is record (role varchar2(20), fetch varchar2(5), alias varchar2(128));
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
    l_ext_obj     json_object_t;   l_ext_text     clob;          l_ext_xml varchar2(32767);
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
      return case l_meta(p_i).fetch
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
      return case l_meta(p_i).fetch
               when 'NUM' then l_num
               when 'VC'  then to_number(l_vc default null on conversion error)
               else null
             end;
    end as_num;

    function as_clob(p_i in pls_integer) return clob is
    begin
      -- CLOB columns pass through; anything else is rendered to text then promoted
      return case when l_meta(p_i).fetch = 'CLOB' then l_clob
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
            dbms_sql.bind_variable(l_c, ':' || l_bkeys(i), l_bobj.get_string(l_bkeys(i)));
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
        if l_m.role = 'GEOM_SDO' then
          l_m.fetch := 'SDO';  dbms_sql.define_column(l_c, i, l_sdo);
        elsif l_desc_t(i).col_type = 112 then           -- CLOB
          l_m.fetch := 'CLOB'; dbms_sql.define_column(l_c, i, l_clob);
        elsif l_desc_t(i).col_type = 2 then             -- NUMBER
          l_m.fetch := 'NUM';  dbms_sql.define_column(l_c, i, l_num);
        elsif l_desc_t(i).col_type = 12 then            -- DATE
          l_m.fetch := 'DATE'; dbms_sql.define_column(l_c, i, l_dat);
        elsif l_desc_t(i).col_type = 180 then           -- TIMESTAMP
          l_m.fetch := 'TS';   dbms_sql.define_column(l_c, i, l_ts);
        elsif l_desc_t(i).col_type = 181 then           -- TIMESTAMP WITH TIME ZONE
          l_m.fetch := 'TSTZ'; dbms_sql.define_column(l_c, i, l_tstz);
        elsif l_desc_t(i).col_type in (1, 96) then      -- VARCHAR2 / CHAR
          l_m.fetch := 'VC';   dbms_sql.define_column(l_c, i, l_vc, 4000);
        else
          l_m.fetch := 'SKIP';
          pck_kml_log.warn(c_pkg, 'run_query',
            'column "' || l_desc_t(i).col_name || '" type ' || l_desc_t(i).col_type
            || ' unsupported; CAST to varchar2/number/date/timestamp in the query', p_job.job_id);
        end if;
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
        if l_meta(i).fetch != 'SKIP' then
          case l_meta(i).fetch
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
            when 'FOLDER_NAME'   then l_folder       := as_vc(i);
            when 'VISIBILITY'    then l_vis          := nvl(upper(substr(as_vc(i), 1, 1)), 'Y');
            when 'ALTITUDE_MODE' then l_alt          := as_vc(i);
            when 'EXTRUDE'       then l_extr         := nvl(upper(substr(as_vc(i), 1, 1)), 'N');
            when 'TESSELLATE'    then l_tess         := nvl(upper(substr(as_vc(i), 1, 1)), 'N');
            when 'ICON_HREF'     then l_icon_href    := as_vc(i);
            when 'ICON_SCALE'    then l_icon_scale   := as_num(i);
            when 'LABEL_COLOR'   then l_label_color  := as_vc(i);
            when 'LABEL_SCALE'   then l_label_scale  := as_num(i);
            when 'LINE_COLOR'    then l_line_color   := as_vc(i);
            when 'LINE_WIDTH'    then l_line_width   := as_num(i);
            when 'POLY_COLOR'    then l_poly_color   := as_vc(i);
            when 'POLY_FILL'     then l_poly_fill    := nvl(upper(substr(as_vc(i), 1, 1)), 'Y');
            when 'POLY_OUTLINE'  then l_poly_outline := nvl(upper(substr(as_vc(i), 1, 1)), 'Y');
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
              exception when others then null;
              end;
            when 'EXT_PROP' then
              if as_vc(i) is not null then
                l_ext_obj.put(l_meta(i).alias, as_vc(i));
              end if;
            else null;  -- IGNORE
          end case;
        end if;
      end loop;

      l_ext_text := case when l_ext_obj.get_size > 0 then l_ext_obj.to_clob end;

      if p_mode = 'MATERIALIZE' then
        if l_geom_sdo is not null
           or (l_geom_geojson is not null and dbms_lob.getlength(l_geom_geojson) > 0)
        then
          l_dummy := pck_kml_job_assets_dml.ins(
            p_job_id           => p_job.job_id,
            p_geometry_sdo     => l_geom_sdo,
            p_geometry_geojson => l_geom_geojson,
            p_name             => l_name,
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
          l_geom := l_geom_kml;
        elsif l_geom_sdo is not null then
          l_geom := geometry_to_kml(l_geom_sdo, null);
        elsif l_geom_geojson is not null and dbms_lob.getlength(l_geom_geojson) > 0 then
          l_geom := geometry_to_kml(null, l_geom_geojson);
        end if;

        if l_geom is not null and dbms_lob.getlength(l_geom) > 0 then
          l_ext_xml := build_extended_data(l_ext_text);
          switch_folder(l_kml, l_open, l_curf, l_folder);
          append_placemark(l_kml, l_name, l_descr, l_ext_xml,
                           build_style_scalar(l_icon_href, l_icon_scale, l_label_color, l_label_scale,
                                              l_line_color, l_line_width,
                                              l_poly_color, l_poly_fill, l_poly_outline),
                           l_geom, l_vis);
          p_count := p_count + 1;
        else
          pck_kml_log.warn(c_pkg, 'run_query', 'STREAM row skipped (no usable geometry)', p_job.job_id);
        end if;
      end if;
    end loop;

    if p_mode != 'MATERIALIZE' and l_open = 'Y' then
      app(l_kml, '</Folder>' || chr(10));
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

  function build_assets_document(p_job_id in number, p_count out number) return clob is
    l_kml clob;
    l_job kml_jobs%rowtype;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);
    dbms_lob.createtemporary(l_kml, true);
    open_document(l_kml, l_job);
    render_from_assets(l_kml, p_job_id, p_count);
    close_document(l_kml);
    return l_kml;
  end build_assets_document;


  function build_query_document(p_job in kml_jobs%rowtype, p_count out number) return clob is
    l_kml clob;
  begin
    dbms_lob.createtemporary(l_kml, true);
    open_document(l_kml, p_job);
    run_query(p_job, 'STREAM', l_kml, p_count);
    close_document(l_kml);
    return l_kml;
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
    pck_kml_jobs_dml.set_running(p_job_id);
    l_job := pck_kml_jobs_dml.get(p_job_id);

    if upper(l_job.source_type) = 'QUERY' and upper(l_job.source_mode) = 'MATERIALIZE' then
      pck_kml_job_assets_dml.del_by_job(p_job_id);          -- idempotent re-run
      run_query(l_job, 'MATERIALIZE', l_void, l_mcount);     -- writes assets
      l_kml := build_assets_document(p_job_id, l_count);     -- render the materialized assets
    elsif upper(l_job.source_type) = 'QUERY' then
      l_kml := build_query_document(l_job, l_count);
    else
      l_kml := build_assets_document(p_job_id, l_count);
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
  exception
    when others then
      rollback;
      pck_kml_jobs_dml.set_failed(p_job_id,
        sqlerrm || chr(10) || dbms_utility.format_error_backtrace);
      commit;
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
