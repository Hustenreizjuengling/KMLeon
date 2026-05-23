--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_JOB_ASSETS_DML  (sole DML access to KML_JOB_ASSETS)
--------------------------------------------------------------------------------
-- Every write to KML_JOB_ASSETS goes through here. Audit columns are auto-stamped
-- when passed NULL. Routines do NOT commit; logging via PCK_KML_LOG.
--------------------------------------------------------------------------------

create or replace package pck_kml_job_assets_dml
  authid definer
as
  c_pkg constant varchar2(30) := 'PCK_KML_JOB_ASSETS_DML';

  -- Supply EXACTLY ONE of p_geometry_sdo / p_geometry_geojson.
  function ins(
    p_job_id           in number,
    p_geometry_sdo     in sdo_geometry default null,
    p_geometry_geojson in clob         default null,
    p_name             in varchar2 default null,
    p_description      in clob     default null,
    p_extended_data    in clob     default null,
    p_folder_name      in varchar2 default null,
    p_display_order    in number   default 0,
    p_altitude_mode    in varchar2 default null,
    p_extrude          in varchar2 default 'N',
    p_tessellate       in varchar2 default 'N',
    p_icon_href        in varchar2 default null,
    p_icon_scale       in number   default null,
    p_label_color      in varchar2 default null,
    p_label_scale      in number   default null,
    p_line_color       in varchar2 default null,
    p_line_width       in number   default null,
    p_poly_color       in varchar2 default null,
    p_poly_fill        in varchar2 default null,
    p_poly_outline     in varchar2 default null,
    p_visibility       in varchar2 default 'Y',
    p_created_by       in varchar2 default null
  ) return number;

  -- Bulk-insert assets from GeoJSON: a FeatureCollection, a single Feature, or a
  -- bare geometry. Each feature's geometry -> geometry_geojson; reserved property
  -- names map to columns; all other properties -> extended_data. Reserved names
  -- mirror the QUERY alias contract (NAME, DESCRIPTION, FOLDER_NAME, VISIBILITY,
  -- DISPLAY_ORDER, ALTITUDE_MODE, EXTRUDE, TESSELLATE, ICON_HREF, ICON_SCALE,
  -- LABEL_COLOR, LABEL_SCALE, LINE_COLOR, LINE_WIDTH, POLY_COLOR, POLY_FILL,
  -- POLY_OUTLINE; case-insensitive). Returns the number of features inserted.
  function add_features_geojson(p_job_id in number, p_feature_collection in clob) return pls_integer;

  procedure del(p_asset_id in number);
  procedure del_by_job(p_job_id in number);
end pck_kml_job_assets_dml;
/

create or replace package body pck_kml_job_assets_dml
as

  function ins(
    p_job_id           in number,
    p_geometry_sdo     in sdo_geometry default null,
    p_geometry_geojson in clob         default null,
    p_name             in varchar2 default null,
    p_description      in clob     default null,
    p_extended_data    in clob     default null,
    p_folder_name      in varchar2 default null,
    p_display_order    in number   default 0,
    p_altitude_mode    in varchar2 default null,
    p_extrude          in varchar2 default 'N',
    p_tessellate       in varchar2 default 'N',
    p_icon_href        in varchar2 default null,
    p_icon_scale       in number   default null,
    p_label_color      in varchar2 default null,
    p_label_scale      in number   default null,
    p_line_color       in varchar2 default null,
    p_line_width       in number   default null,
    p_poly_color       in varchar2 default null,
    p_poly_fill        in varchar2 default null,
    p_poly_outline     in varchar2 default null,
    p_visibility       in varchar2 default 'Y',
    p_created_by       in varchar2 default null
  ) return number
  is
    l_id  number;
    l_now timestamp     := systimestamp;
    l_who varchar2(128) := nvl(p_created_by, user);
  begin
    if p_geometry_sdo is null
       and (p_geometry_geojson is null or dbms_lob.getlength(p_geometry_geojson) = 0)
    then
      raise_application_error(-20820,
        'Asset for job ' || p_job_id || ' has no geometry (provide SDO or GeoJSON).');
    end if;

    insert into kml_job_assets (
      job_id, geometry_sdo, geometry_geojson, name, description, extended_data,
      folder_name, display_order, altitude_mode, extrude, tessellate,
      icon_href, icon_scale, label_color, label_scale,
      line_color, line_width, poly_color, poly_fill, poly_outline, visibility,
      created_at, created_by, updated_at, updated_by
    ) values (
      p_job_id, p_geometry_sdo, p_geometry_geojson, p_name, p_description, p_extended_data,
      p_folder_name, p_display_order, p_altitude_mode, p_extrude, p_tessellate,
      p_icon_href, p_icon_scale, p_label_color, p_label_scale,
      p_line_color, p_line_width, p_poly_color, p_poly_fill, p_poly_outline, p_visibility,
      l_now, l_who, l_now, l_who
    ) returning asset_id into l_id;

    pck_kml_log.debug(c_pkg, 'ins', 'added asset "' || p_name || '"', p_job_id);
    return l_id;
  end ins;


  --------------------------------------------------------------------------------
  -- GeoJSON ingestion (shared feature-mapping contract; see PCK_KML_ENGINE)
  --------------------------------------------------------------------------------

  function prop_role(p_key in varchar2) return varchar2 is
    a varchar2(128) := upper(p_key);
  begin
    return case a
      when 'NAME'          then 'NAME'
      when 'DESCRIPTION'   then 'DESCRIPTION'
      when 'FOLDER_NAME'   then 'FOLDER_NAME'
      when 'VISIBILITY'    then 'VISIBILITY'
      when 'DISPLAY_ORDER' then 'DISPLAY_ORDER'
      when 'ALTITUDE_MODE' then 'ALTITUDE_MODE'
      when 'EXTRUDE'       then 'EXTRUDE'
      when 'TESSELLATE'    then 'TESSELLATE'
      when 'ICON_HREF'     then 'ICON_HREF'
      when 'ICON_SCALE'    then 'ICON_SCALE'
      when 'LABEL_COLOR'   then 'LABEL_COLOR'
      when 'LABEL_SCALE'   then 'LABEL_SCALE'
      when 'LINE_COLOR'    then 'LINE_COLOR'
      when 'LINE_WIDTH'    then 'LINE_WIDTH'
      when 'POLY_COLOR'    then 'POLY_COLOR'
      when 'POLY_FILL'     then 'POLY_FILL'
      when 'POLY_OUTLINE'  then 'POLY_OUTLINE'
      else 'EXT'
    end;
  end prop_role;

  -- scalar property as text (coerces non-string scalars best-effort)
  function pstr(p_obj in json_object_t, p_key in varchar2) return varchar2 is
  begin
    return p_obj.get_string(p_key);
  exception
    when others then
      begin
        return p_obj.get(p_key).to_string;
      exception when others then return null; end;
  end pstr;

  function pnum(p_obj in json_object_t, p_key in varchar2) return number is
  begin
    return p_obj.get_number(p_key);
  exception
    when others then
      return to_number(pstr(p_obj, p_key) default null on conversion error);
  end pnum;


  function add_features_geojson(p_job_id in number, p_feature_collection in clob) return pls_integer is
    l_root      json_object_t;
    l_feats     json_array_t;
    l_el        json_element_t;
    l_feat      json_object_t;
    l_props     json_object_t;
    l_keys      json_key_list;
    l_ext       json_object_t;
    l_geom_obj  json_object_t;
    l_geom_clob clob;
    l_count     pls_integer := 0;
    l_dummy     number;
    -- per-feature reserved values
    l_name varchar2(4000); l_descr clob; l_folder varchar2(1000); l_vis varchar2(1);
    l_alt varchar2(20); l_extr varchar2(1); l_tess varchar2(1); l_disp number;
    l_icon_href varchar2(1000); l_icon_scale number; l_label_color varchar2(8); l_label_scale number;
    l_line_color varchar2(8); l_line_width number;
    l_poly_color varchar2(8); l_poly_fill varchar2(1); l_poly_outline varchar2(1);
  begin
    if p_feature_collection is null or dbms_lob.getlength(p_feature_collection) = 0 then
      return 0;
    end if;
    l_root := json_object_t.parse(p_feature_collection);

    if l_root.has('features') then
      l_feats := l_root.get_array('features');
    else
      l_feats := json_array_t();      -- a single Feature or a bare geometry
      l_feats.append(l_root);
    end if;

    for i in 0 .. l_feats.get_size - 1 loop
      l_el := l_feats.get(i);
      if l_el.is_object then
        l_feat := treat(l_el as json_object_t);

        -- reset per feature
        l_name := null; l_descr := null; l_folder := null; l_vis := 'Y';
        l_alt := null; l_extr := 'N'; l_tess := 'N'; l_disp := 0;
        l_icon_href := null; l_icon_scale := null; l_label_color := null; l_label_scale := null;
        l_line_color := null; l_line_width := null;
        l_poly_color := null; l_poly_fill := null; l_poly_outline := null;
        l_ext := json_object_t();

        if l_feat.has('geometry') then
          l_geom_obj := l_feat.get_object('geometry');
          l_props    := l_feat.get_object('properties');
        else
          l_geom_obj := l_feat;       -- bare geometry
          l_props    := null;
        end if;

        if l_geom_obj is null then
          pck_kml_log.warn(c_pkg, 'add_features_geojson', 'feature without geometry skipped', p_job_id);
        else
          l_geom_clob := l_geom_obj.to_clob;

          if l_props is not null then
            l_keys := l_props.get_keys;
            for k in 1 .. l_keys.count loop
              case prop_role(l_keys(k))
                when 'NAME'          then l_name         := pstr(l_props, l_keys(k));
                when 'DESCRIPTION'   then l_descr        := to_clob(pstr(l_props, l_keys(k)));
                when 'FOLDER_NAME'   then l_folder       := pstr(l_props, l_keys(k));
                when 'VISIBILITY'    then l_vis          := nvl(upper(substr(pstr(l_props, l_keys(k)), 1, 1)), 'Y');
                when 'DISPLAY_ORDER' then l_disp         := nvl(pnum(l_props, l_keys(k)), 0);
                when 'ALTITUDE_MODE' then l_alt          := pstr(l_props, l_keys(k));
                when 'EXTRUDE'       then l_extr         := nvl(upper(substr(pstr(l_props, l_keys(k)), 1, 1)), 'N');
                when 'TESSELLATE'    then l_tess         := nvl(upper(substr(pstr(l_props, l_keys(k)), 1, 1)), 'N');
                when 'ICON_HREF'     then l_icon_href    := pstr(l_props, l_keys(k));
                when 'ICON_SCALE'    then l_icon_scale   := pnum(l_props, l_keys(k));
                when 'LABEL_COLOR'   then l_label_color  := pstr(l_props, l_keys(k));
                when 'LABEL_SCALE'   then l_label_scale  := pnum(l_props, l_keys(k));
                when 'LINE_COLOR'    then l_line_color   := pstr(l_props, l_keys(k));
                when 'LINE_WIDTH'    then l_line_width   := pnum(l_props, l_keys(k));
                when 'POLY_COLOR'    then l_poly_color   := pstr(l_props, l_keys(k));
                when 'POLY_FILL'     then l_poly_fill    := nvl(upper(substr(pstr(l_props, l_keys(k)), 1, 1)), 'Y');
                when 'POLY_OUTLINE'  then l_poly_outline := nvl(upper(substr(pstr(l_props, l_keys(k)), 1, 1)), 'Y');
                else l_ext.put(l_keys(k), l_props.get(l_keys(k)));
              end case;
            end loop;
          end if;

          l_dummy := ins(
            p_job_id           => p_job_id,
            p_geometry_geojson => l_geom_clob,
            p_name             => l_name,
            p_description      => l_descr,
            p_extended_data    => case when l_ext.get_size > 0 then l_ext.to_clob end,
            p_folder_name      => l_folder,
            p_display_order    => l_disp,
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
          l_count := l_count + 1;
        end if;
      end if;
    end loop;

    pck_kml_log.info(c_pkg, 'add_features_geojson', 'added ' || l_count || ' feature(s)', p_job_id);
    return l_count;
  end add_features_geojson;


  procedure del(p_asset_id in number) is
  begin
    delete from kml_job_assets where asset_id = p_asset_id;
    pck_kml_log.debug(c_pkg, 'del', 'deleted asset ' || p_asset_id);
  end del;


  procedure del_by_job(p_job_id in number) is
  begin
    delete from kml_job_assets where job_id = p_job_id;
    pck_kml_log.debug(c_pkg, 'del_by_job', 'deleted rows=' || sql%rowcount, p_job_id);
  end del_by_job;

end pck_kml_job_assets_dml;
/
