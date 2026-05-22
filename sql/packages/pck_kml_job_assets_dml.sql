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
