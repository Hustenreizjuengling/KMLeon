--------------------------------------------------------------------------------
-- KMLeon Toolkit :: PCK_KMLEON_TOOLS
--------------------------------------------------------------------------------
-- Helper functions the APEX toolkit app calls from its pages. Lives in the
-- KMLeon schema so the engine's definer-rights dynamic SQL can invoke them.
--
-- Members:
--   row_sleep    - per-row sleep used by the Async playground SELECT
--   qstring      - wrap a CLOB in a safe q'<delim>...<delim>' literal
--   role_of      - map a SELECT column alias to its KMLeon role
--   type_name    - friendly name for a DBMS_SQL describe-column type code
--   query_helper - parse + describe a candidate SELECT, build ready-to-paste
--                  PL/SQL snippets and a role table (used by the Query helper page)
--------------------------------------------------------------------------------

create or replace package pck_kmleon_tools
  authid definer
as
  -- Sleeps p_seconds (DBMS_SESSION.SLEEP, 19c) and returns p_seconds. Used as a
  -- per-row delay in slow-query demonstrations on the Async playground page.
  function row_sleep(p_seconds in number) return number;

  -- Wrap p_text in a q-literal, picking a delimiter pair whose closing token
  -- does not appear in the text. Falls back to traditional ''-doubling if every
  -- candidate is unsafe (extremely rare for SELECT statements).
  function qstring(p_text in clob) return clob;

  -- Resolve a SELECT column alias to its KMLeon role (the run_query contract):
  -- reserved names map to specific roles, everything else becomes ExtendedData.
  function role_of(p_alias in varchar2) return varchar2;

  -- Friendly name for a DBMS_SQL.DESC_REC3.col_type numeric code.
  function type_name(p_type in number, p_len in number) return varchar2;

  -- The schema unqualified names resolve to inside this package. Because the
  -- package is AUTHID DEFINER, this is the package owner -- i.e. the schema the
  -- KMLeon engine will use when it later executes the query.
  function engine_schema return varchar2;

  -- Analyse a candidate SELECT for use as a KMLeon QUERY source.
  --   p_columns    : text table of ALIAS / TYPE / KMLEON ROLE (DBMS_SQL describe)
  --   p_snippet    : full anonymous PL/SQL block calling PCK_KML_JOB_API.create_job_from_query
  --   p_query_clob : one-liner "l_query clob := q'<delim>...<delim>';"
  --   p_status     : 'OK' or the parse/runtime error text
  procedure query_helper(
    p_query      in  clob,
    p_binds      in  clob     default null,
    p_doc_name   in  varchar2 default 'My export',
    p_format     in  varchar2 default 'KMZ',
    p_columns    out clob,
    p_snippet    out clob,
    p_query_clob out clob,
    p_status     out varchar2
  );
end pck_kmleon_tools;
/

create or replace package body pck_kmleon_tools
as

  function row_sleep(p_seconds in number) return number is
  begin
    sys.dbms_session.sleep(nvl(p_seconds, 1));
    return nvl(p_seconds, 1);
  end row_sleep;


  function qstring(p_text in clob) return clob is
    type t_delims is varray(9) of varchar2(1);
    c_open  constant t_delims := t_delims('~','{','[','(','<','#','!','^','*');
    c_close constant t_delims := t_delims('~','}',']',')','>','#','!','^','*');
  begin
    if p_text is null then
      return null;
    end if;
    for i in 1 .. c_open.count loop
      if dbms_lob.instr(p_text, c_close(i) || '''') = 0 then
        return 'q''' || c_open(i) || p_text || c_close(i) || '''';
      end if;
    end loop;
    return '''' || replace(p_text, '''', '''''') || '''';
  end qstring;


  function role_of(p_alias in varchar2) return varchar2 is
    l_a varchar2(128) := upper(p_alias);
  begin
    return case l_a
      when 'GEOMETRY'         then 'GEOMETRY (SDO)'
      when 'GEOMETRY_SDO'     then 'GEOMETRY (SDO)'
      when 'GEOMETRY_GEOJSON' then 'GEOMETRY (GeoJSON)'
      when 'GEOMETRY_KML'     then 'GEOMETRY (KML passthrough)'
      when 'NAME'             then 'NAME (placemark)'
      when 'DESCRIPTION'      then 'DESCRIPTION (balloon, HTML)'
      when 'FOLDER_NAME'      then 'FOLDER_NAME (/ nests)'
      when 'VISIBILITY'       then 'VISIBILITY (Y/N)'
      when 'DISPLAY_ORDER'    then 'DISPLAY_ORDER'
      when 'ALTITUDE_MODE'    then 'ALTITUDE_MODE'
      when 'EXTRUDE'          then 'EXTRUDE (Y/N, 3D)'
      when 'TESSELLATE'       then 'TESSELLATE (Y/N, 3D)'
      when 'ICON_HREF'        then 'ICON_HREF (style)'
      when 'ICON_SCALE'       then 'ICON_SCALE (style)'
      when 'LABEL_COLOR'      then 'LABEL_COLOR (aabbggrr)'
      when 'LABEL_SCALE'      then 'LABEL_SCALE'
      when 'LINE_COLOR'       then 'LINE_COLOR (aabbggrr)'
      when 'LINE_WIDTH'       then 'LINE_WIDTH'
      when 'POLY_COLOR'       then 'POLY_COLOR (aabbggrr)'
      when 'POLY_FILL'        then 'POLY_FILL (Y/N)'
      when 'POLY_OUTLINE'     then 'POLY_OUTLINE (Y/N)'
      when 'EXTENDED_DATA'    then 'EXTENDED_DATA (JSON)'
      else 'ExtendedData property (key: ' || lower(p_alias) || ')'
    end;
  end role_of;


  function engine_schema return varchar2 is
  begin
    return sys_context('USERENV', 'CURRENT_SCHEMA');
  end engine_schema;


  function type_name(p_type in number, p_len in number) return varchar2 is
  begin
    return case p_type
      when   1 then 'VARCHAR2(' || p_len || ')'
      when   2 then 'NUMBER'
      when  12 then 'DATE'
      when  96 then 'CHAR(' || p_len || ')'
      when 100 then 'BINARY_FLOAT'
      when 101 then 'BINARY_DOUBLE'
      when 109 then 'OBJECT (e.g. SDO_GEOMETRY)'
      when 112 then 'CLOB'
      when 113 then 'BLOB'
      when 180 then 'TIMESTAMP'
      when 181 then 'TIMESTAMP WITH TIME ZONE'
      when 231 then 'TIMESTAMP WITH LOCAL TIME ZONE'
      else 'type(' || p_type || ')'
    end;
  end type_name;


  procedure query_helper(
    p_query      in  clob,
    p_binds      in  clob     default null,
    p_doc_name   in  varchar2 default 'My export',
    p_format     in  varchar2 default 'KMZ',
    p_columns    out clob,
    p_snippet    out clob,
    p_query_clob out clob,
    p_status     out varchar2
  ) is
    l_c     integer;
    l_cols  number;
    l_desc  dbms_sql.desc_tab3;
    l_bobj  json_object_t;
    l_bkeys json_key_list;
    l_q     clob;
  begin
    p_status     := 'OK -- parsed against engine schema ' || engine_schema;
    p_columns    := to_clob('');
    p_snippet    := to_clob('');
    p_query_clob := to_clob('');

    if p_query is null or dbms_lob.getlength(p_query) = 0 then
      p_status := 'Query is empty.';
      return;
    end if;

    l_c := dbms_sql.open_cursor;
    begin
      dbms_sql.parse(l_c, p_query, dbms_sql.native);
    exception
      when others then
        p_status := 'Parse error in engine schema ' || engine_schema || ': ' || sqlerrm
                 || ' -- tables in other schemas need qualified names (SCHEMA.TABLE), a synonym in '
                 || engine_schema || ', or a DB link.';
        if dbms_sql.is_open(l_c) then dbms_sql.close_cursor(l_c); end if;
        return;
    end;

    -- best-effort bind from p_binds JSON (mirrors the engine's run_query behaviour)
    if p_binds is not null and dbms_lob.getlength(p_binds) > 0 then
      begin
        l_bobj  := json_object_t.parse(p_binds);
        l_bkeys := l_bobj.get_keys;
        for i in 1 .. l_bkeys.count loop
          begin
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
          exception when others then null;
          end;
        end loop;
      exception when others then
        p_status := 'OK (binds JSON ignored: ' || sqlerrm || ')';
      end;
    end if;

    dbms_sql.describe_columns3(l_c, l_cols, l_desc);

    p_columns := p_columns || rpad('ALIAS', 32) || rpad('TYPE', 32) || 'KMLEON ROLE' || chr(10);
    p_columns := p_columns || rpad('-----', 32) || rpad('----', 32) || '-----------' || chr(10);
    for i in 1 .. l_cols loop
      p_columns := p_columns
                || rpad(l_desc(i).col_name, 32)
                || rpad(type_name(l_desc(i).col_type, l_desc(i).col_max_len), 32)
                || role_of(l_desc(i).col_name) || chr(10);
    end loop;

    if dbms_sql.is_open(l_c) then dbms_sql.close_cursor(l_c); end if;

    l_q          := qstring(p_query);
    p_query_clob := 'l_query clob := ' || l_q || ';';

    p_snippet := p_snippet
              || 'declare'                                                                              || chr(10)
              || '  l_job number;'                                                                       || chr(10)
              || 'begin'                                                                                 || chr(10)
              || '  l_job := pck_kml_job_api.create_job_from_query('                                     || chr(10)
              || '    p_document_name => ''' || replace(nvl(p_doc_name,'My export'),'''','''''') || ''',' || chr(10)
              || '    p_output_format => ''' || nvl(upper(p_format),'KMZ') || ''','                      || chr(10);
    if p_binds is not null and dbms_lob.getlength(p_binds) > 0 then
      p_snippet := p_snippet
                || '    p_source_binds  => ' || qstring(p_binds) || ',' || chr(10);
    end if;
    p_snippet := p_snippet
              || '    p_source_query  => ' || l_q || ');'                                                || chr(10)
              || '  commit;'                                                                             || chr(10)
              || '  pck_kml_job_api.run_async(l_job);   -- or run_now / submit_job(...)'                 || chr(10)
              || 'end;'                                                                                  || chr(10)
              || '/';

  exception
    when others then
      p_status := 'Error: ' || sqlerrm;
      begin
        if dbms_sql.is_open(l_c) then dbms_sql.close_cursor(l_c); end if;
      exception when others then null;
      end;
  end query_helper;

end pck_kmleon_tools;
/
