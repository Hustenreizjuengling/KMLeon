--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_ENGINE  (generic KML/KMZ generation)
--------------------------------------------------------------------------------
-- Turns KML_JOBS + KML_JOB_ASSETS rows into a KML document (and optionally KMZ).
-- Reads the tables directly (SELECT is allowed); ALL writes go through the DML
-- packages. Geometry is converted natively via SDO_UTIL, so no custom WKT parser.
-- Requires Oracle Spatial/Locator (SDO_UTIL).
--------------------------------------------------------------------------------

create or replace package pck_kml_engine
  authid definer
as
  c_pkg     constant varchar2(30)  := 'PCK_KML_ENGINE';
  gc_kml_ns constant varchar2(100) := 'http://www.opengis.net/kml/2.2';

  -- Convert one asset's geometry (SDO or GeoJSON) into a KML geometry fragment.
  function geometry_to_kml(p_sdo in sdo_geometry, p_geojson in clob) return clob;

  -- Build the complete KML document for a job (read-only; no commit).
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
  -- Helpers
  --==============================================================================

  function escape_xml(p_text in varchar2) return varchar2 is
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
      -- bad geometry should not abort the whole document; skip this fragment
      pck_kml_log.warn(c_pkg, 'geometry_to_kml', sqlerrm);
      return null;
  end geometry_to_kml;


  --==============================================================================
  -- Styling and ExtendedData
  --==============================================================================

  function build_style(p_asset in kml_job_assets%rowtype) return varchar2 is
    l_out varchar2(4000);
  begin
    if p_asset.icon_href is null and p_asset.icon_scale is null
       and p_asset.label_color is null and p_asset.label_scale is null
       and p_asset.line_color is null and p_asset.line_width is null
       and p_asset.poly_color is null and p_asset.poly_fill is null
       and p_asset.poly_outline is null
    then
      return null;
    end if;

    l_out := '<Style>';

    if p_asset.icon_href is not null or p_asset.icon_scale is not null then
      l_out := l_out || '<IconStyle>';
      if p_asset.icon_scale is not null then
        l_out := l_out || '<scale>' || num(p_asset.icon_scale) || '</scale>';
      end if;
      if p_asset.icon_href is not null then
        l_out := l_out || '<Icon><href>' || escape_xml(p_asset.icon_href) || '</href></Icon>';
      end if;
      l_out := l_out || '</IconStyle>';
    end if;

    if p_asset.label_color is not null or p_asset.label_scale is not null then
      l_out := l_out || '<LabelStyle>';
      if p_asset.label_color is not null then
        l_out := l_out || '<color>' || lower(p_asset.label_color) || '</color>';
      end if;
      if p_asset.label_scale is not null then
        l_out := l_out || '<scale>' || num(p_asset.label_scale) || '</scale>';
      end if;
      l_out := l_out || '</LabelStyle>';
    end if;

    if p_asset.line_color is not null or p_asset.line_width is not null then
      l_out := l_out || '<LineStyle>';
      if p_asset.line_color is not null then
        l_out := l_out || '<color>' || lower(p_asset.line_color) || '</color>';
      end if;
      if p_asset.line_width is not null then
        l_out := l_out || '<width>' || num(p_asset.line_width) || '</width>';
      end if;
      l_out := l_out || '</LineStyle>';
    end if;

    if p_asset.poly_color is not null or p_asset.poly_fill is not null
       or p_asset.poly_outline is not null
    then
      l_out := l_out || '<PolyStyle>';
      if p_asset.poly_color is not null then
        l_out := l_out || '<color>' || lower(p_asset.poly_color) || '</color>';
      end if;
      if p_asset.poly_fill is not null then
        l_out := l_out || '<fill>' || case when p_asset.poly_fill = 'Y' then '1' else '0' end || '</fill>';
      end if;
      if p_asset.poly_outline is not null then
        l_out := l_out || '<outline>' || case when p_asset.poly_outline = 'Y' then '1' else '0' end || '</outline>';
      end if;
      l_out := l_out || '</PolyStyle>';
    end if;

    return l_out || '</Style>';
  end build_style;


  -- Render an arbitrary JSON object as <ExtendedData>. Best-effort: any problem
  -- (no JSON support, malformed input) simply omits the block.
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
            || '<value>' || escape_xml(l_obj.get_string(l_keys(i))) || '</value>'
            || '</Data>';
    end loop;
    return l_out || '</ExtendedData>';
  exception
    when others then
      return null;
  end build_extended_data;


  --==============================================================================
  -- Document assembly
  --==============================================================================

  function build_kml(p_job_id in number) return clob is
    l_kml  clob;
    l_job  kml_jobs%rowtype;
    l_open varchar2(1)    := 'N';        -- is a <Folder> currently open?
    l_cur  varchar2(1000) := '##INIT##';
    l_desc clob;
    l_geom clob;

    procedure app(p_text in varchar2) is
    begin
      if p_text is not null then
        dbms_lob.writeappend(l_kml, length(p_text), p_text);
      end if;
    end app;

    procedure appc(p_clob in clob) is
    begin
      if p_clob is not null and dbms_lob.getlength(p_clob) > 0 then
        dbms_lob.append(l_kml, p_clob);
      end if;
    end appc;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);

    dbms_lob.createtemporary(l_kml, true);
    app('<?xml version="1.0" encoding="UTF-8"?>' || chr(10));
    app('<kml xmlns="' || gc_kml_ns || '">' || chr(10));
    app('<Document>');
    app('<name>' || escape_xml(nvl(l_job.document_name, 'KMLeon export')) || '</name>');
    if l_job.description is not null then
      app('<description>' || escape_xml(l_job.description) || '</description>');
    end if;
    app(chr(10));

    -- NULL-folder assets first (no wrapper), then one <Folder> per group.
    for r in (
      select *
        from kml_job_assets
       where job_id = p_job_id
       order by case when folder_name is null then 0 else 1 end,
                folder_name, display_order, asset_id
    ) loop
      if nvl(r.folder_name, '##NULL##') <> nvl(l_cur, '##NULL##') then
        if l_open = 'Y' then
          app('</Folder>' || chr(10));
          l_open := 'N';
        end if;
        if r.folder_name is not null then
          app('<Folder><name>' || escape_xml(r.folder_name) || '</name>' || chr(10));
          l_open := 'Y';
        end if;
        l_cur := r.folder_name;
      end if;

      l_geom := geometry_to_kml(r.geometry_sdo, r.geometry_geojson);
      if l_geom is not null and dbms_lob.getlength(l_geom) > 0 then
        app('<Placemark>');
        if r.visibility = 'N' then
          app('<visibility>0</visibility>');
        end if;
        if r.name is not null then
          app('<name>' || escape_xml(r.name) || '</name>');
        end if;
        if r.description is not null and dbms_lob.getlength(r.description) > 0 then
          l_desc := replace(r.description, ']]>', ']]]]><![CDATA[>');
          app('<description><![CDATA[');
          appc(l_desc);
          app(']]></description>');
        end if;
        app(build_style(r));
        app(build_extended_data(r.extended_data));
        appc(l_geom);
        app('</Placemark>' || chr(10));
      else
        pck_kml_log.warn(c_pkg, 'build_kml',
                         'asset ' || r.asset_id || ' skipped (no usable geometry)', p_job_id);
      end if;
    end loop;

    if l_open = 'Y' then
      app('</Folder>' || chr(10));
    end if;

    app('</Document>' || chr(10));
    app('</kml>' || chr(10));
    return l_kml;
  end build_kml;


  --==============================================================================
  -- Job execution
  --==============================================================================

  procedure run_job(p_job_id in number) is
    l_job   kml_jobs%rowtype;
    l_kml   clob;
    l_kmz   blob;
    l_count number;
  begin
    pck_kml_jobs_dml.set_running(p_job_id);
    l_job := pck_kml_jobs_dml.get(p_job_id);

    l_kml := build_kml(p_job_id);
    select count(*) into l_count from kml_job_assets where job_id = p_job_id;

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
