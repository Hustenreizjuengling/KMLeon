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

  -- Like qstring, but split the literal at every occurrence of each name in
  -- p_inline_names (comma-separated, without leading ':') so the result becomes
  -- q'<o>prefix<c>' || :name || q'<o>suffix<c>' -- ready to drop into PL/SQL
  -- where the CALLING session (e.g. an APEX DA) resolves :name (an APEX item)
  -- BEFORE the query is stored on the job. Names not listed stay as engine
  -- binds in the q-literal and are bound at job time via source_binds.
  function qstring_inline(p_text in clob, p_inline_names in varchar2) return clob;

  -- Scan p_text for :NAME bind placeholders and return the distinct names
  -- (upper-cased, comma-separated), optionally excluding any in p_exclude_csv
  -- (also case-insensitive). Used by query_helper to auto-detect which binds
  -- should be inlined when the caller did not list them explicitly.
  function detect_binds(p_text in clob, p_exclude_csv in varchar2 default null) return varchar2;

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
    p_query        in  clob,
    p_binds        in  clob     default null,
    p_doc_name     in  varchar2 default 'My export',
    p_format       in  varchar2 default 'KMZ',
    p_inline_binds in  varchar2 default null,        -- comma-separated APEX item names
    p_bind_mode    in  varchar2 default 'QUERY',     -- 'QUERY' = inline value via concat into source_query;
                                                     -- 'JSON'  = inline value via concat into source_binds JSON,
                                                     --          query keeps :NAME and engine binds at runtime
    p_columns      out clob,
    p_snippet      out clob,
    p_query_clob   out clob,
    p_status       out varchar2
  );

  -- Convert a KML aabbggrr color back to an HTML #RRGGBB string (for loading a
  -- stored asset's color into a color picker). Returns NULL on bad input.
  function kml_to_rgb(p_kml in varchar2) return varchar2;

  -- Extract the alpha (0..255) from a KML aabbggrr color. Returns NULL on bad input.
  function kml_alpha(p_kml in varchar2) return number;

  -- Style helper for the Editor page. Given a feature's geometry (GeoJSON) and
  -- style choices (colors as #RRGGBB or RRGGBB; the leading # is tolerated),
  -- produce two ready-to-paste artefacts:
  --   p_snippet    : a PCK_KML_JOB_API.add_asset(...) call (colors via rgba_to_kml)
  --   p_kml_style  : the raw KML <Style>...</Style> fragment
  -- Pass-through alphas are 0..255 (default 255; polygon fill default 128). Any
  -- color left null/empty omits that sub-style and the matching add_asset param.
  procedure style_outputs(
    p_geojson       in  clob     default null,
    p_name          in  varchar2 default null,
    p_folder_name   in  varchar2 default null,
    p_line_color    in  varchar2 default null,   -- #RRGGBB
    p_line_width    in  number   default null,
    p_poly_color    in  varchar2 default null,   -- #RRGGBB
    p_poly_alpha    in  number   default 128,    -- fill opacity 0..255
    p_poly_fill     in  varchar2 default 'Y',
    p_poly_outline  in  varchar2 default 'Y',
    p_label_color   in  varchar2 default null,   -- #RRGGBB
    p_label_scale   in  number   default null,
    p_icon_href     in  varchar2 default null,
    p_icon_scale    in  number   default null,
    p_altitude_mode in  varchar2 default null,
    p_extrude       in  varchar2 default 'N',
    p_tessellate    in  varchar2 default 'N',
    p_extended_data in  clob     default null,   -- JSON object -> ExtendedData
    p_snippet       out clob,
    p_kml_style     out clob
  );

  -- REST helper for the Editor page. Produces ready-to-paste curl scripts that use
  -- the KMLeon ORDS API (sql/ords/010_rest_api.sql):
  --   p_asset_rest : POST the current geometry + style as ONE GeoJSON feature to an
  --                  existing job's /features endpoint (colors via rgba_to_kml).
  --   p_job_rest   : the WHOLE selected job (p_job_id) as a curl sequence -- create
  --                  the job, POST all its assets as a FeatureCollection, run it,
  --                  and download the result. Stored asset colors are aabbggrr.
  -- p_base_url is the ORDS base, e.g. https://host/ords/kml/kmleon/v1 (no trailing /).
  procedure rest_outputs(
    p_job_id        in  number   default null,
    p_geojson       in  clob     default null,
    p_name          in  varchar2 default null,
    p_folder_name   in  varchar2 default null,
    p_line_color    in  varchar2 default null,   -- #RRGGBB
    p_line_width    in  number   default null,
    p_poly_color    in  varchar2 default null,   -- #RRGGBB
    p_poly_alpha    in  number   default 128,
    p_poly_fill     in  varchar2 default 'Y',
    p_poly_outline  in  varchar2 default 'Y',
    p_label_color   in  varchar2 default null,   -- #RRGGBB
    p_label_scale   in  number   default null,
    p_icon_href     in  varchar2 default null,
    p_icon_scale    in  number   default null,
    p_altitude_mode in  varchar2 default null,
    p_extrude       in  varchar2 default 'N',
    p_tessellate    in  varchar2 default 'N',
    p_extended_data in  clob     default null,   -- JSON object -> ExtendedData
    p_base_url      in  varchar2 default 'https://HOST/ords/SCHEMA/kmleon/v1',
    p_asset_rest    out clob,
    p_job_rest      out clob
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


  function qstring_inline(p_text in clob, p_inline_names in varchar2) return clob is
    type t_delims is varray(9) of varchar2(1);
    c_open  constant t_delims := t_delims('~','{','[','(','<','#','!','^','*');
    c_close constant t_delims := t_delims('~','}',']',')','>','#','!','^','*');
    l_text  clob := p_text;
    l_names varchar2(2000);
    l_open  varchar2(1);
    l_close varchar2(1);
    l_name  varchar2(128);
    l_idx   pls_integer := 1;
    l_out   clob;
  begin
    if p_text is null then
      return null;
    end if;
    if p_inline_names is null or trim(p_inline_names) is null then
      return qstring(p_text);
    end if;

    -- choose a safe q-delimiter for the WHOLE wrapped text (closer not in text)
    for i in 1 .. c_open.count loop
      if dbms_lob.instr(p_text, c_close(i) || '''') = 0 then
        l_open  := c_open(i);
        l_close := c_close(i);
        exit;
      end if;
    end loop;
    if l_open is null then
      return qstring(p_text);   -- no safe delim; cannot inline-interpolate
    end if;

    -- replace each inline placeholder (case-insensitive, word-boundary aware):
    --   :NAME  ->  <close>' || :NAME || q'<open>
    l_names := replace(p_inline_names, ' ');
    loop
      l_name := upper(trim(regexp_substr(l_names, '[^,]+', 1, l_idx)));
      exit when l_name is null;
      l_name := ltrim(l_name, ':');   -- tolerate ':P200_ID' as well as 'P200_ID'
      if length(l_name) > 0 then
        -- Oracle's POSIX regex has no reliable \b word boundary, so match the
        -- next non-word character (or end of text) explicitly and put it back
        -- via the \1 backreference.
        l_text := regexp_replace(l_text,
                    ':' || l_name || '([^A-Za-z0-9_]|$)',
                    l_close || ''' || :' || l_name || ' || q''' || l_open || '\1',
                    1, 0, 'i');
      end if;
      l_idx := l_idx + 1;
    end loop;

    l_out := 'q''' || l_open || l_text || l_close || '''';

    -- tidy up empty leading / trailing q-literals from the wrapping
    l_out := regexp_replace(l_out, '^q''' || l_open || l_close || '''\s*\|\|\s*', '');
    l_out := regexp_replace(l_out, '\s*\|\|\s*q''' || l_open || l_close || '''$', '');

    return l_out;
  end qstring_inline;


  function detect_binds(p_text in clob, p_exclude_csv in varchar2 default null) return varchar2 is
    l_excl  varchar2(4000) := ',' || upper(replace(nvl(p_exclude_csv, ''), ' ')) || ',';
    l_seen  varchar2(4000) := ',';
    l_out   varchar2(4000);
    l_name  varchar2(128);
    l_n     pls_integer := 1;
  begin
    if p_text is null then return null; end if;
    loop
      l_name := upper(regexp_substr(p_text, ':([A-Za-z][A-Za-z0-9_]*)', 1, l_n, null, 1));
      exit when l_name is null;
      l_n := l_n + 1;
      if instr(l_seen, ',' || l_name || ',') = 0
         and instr(l_excl, ',' || l_name || ',') = 0 then
        l_out  := case when l_out is null then l_name else l_out || ',' || l_name end;
        l_seen := l_seen || l_name || ',';
      end if;
    end loop;
    return l_out;
  end detect_binds;


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


  -- Build the PL/SQL expression that produces the final source_binds JSON at
  -- runtime, combining the static engine JSON (p_engine_json) with caller-resolved
  -- inline binds (p_inline_csv). Inline values are concatenated with ||:NAME|| so
  -- the calling session resolves them at submit time (e.g. APEX page items).
  -- All inline values are wrapped as JSON STRINGs (Oracle converts to NUMBER on
  -- bind if the column type requires it).
  function build_binds_expr(p_engine_json in clob, p_inline_csv in varchar2) return clob is
    c_q     constant varchar2(1) := '''';   -- a literal single quote
    l_eng   varchar2(32767);
    l_out   clob;
    l_names varchar2(2000);
    l_name  varchar2(128);
    l_idx   pls_integer := 1;
    l_has   boolean := false;
  begin
    if (p_engine_json is null or dbms_lob.getlength(p_engine_json) = 0)
       and (p_inline_csv is null or trim(p_inline_csv) is null) then
      return null;
    end if;

    -- shortcut: no inline binds -> just wrap the engine JSON literally
    if p_inline_csv is null or trim(p_inline_csv) is null then
      return qstring(p_engine_json);
    end if;

    l_out := c_q || '{';

    -- strip the outer braces of the engine JSON and embed its contents
    if p_engine_json is not null and dbms_lob.getlength(p_engine_json) > 0 then
      l_eng := trim(p_engine_json);
      if substr(l_eng, 1, 1) = '{'  then l_eng := substr(l_eng, 2);                       end if;
      if substr(l_eng, -1)   = '}'  then l_eng := substr(l_eng, 1, length(l_eng) - 1);    end if;
      l_eng := trim(l_eng);
      if length(nvl(l_eng, '')) > 0 then
        l_out := l_out || l_eng;
        l_has := true;
      end if;
    end if;

    -- append each inline bind as: "NAME":"' || :NAME || '"
    l_names := replace(p_inline_csv, ' ');
    loop
      l_name := upper(trim(regexp_substr(l_names, '[^,]+', 1, l_idx)));
      exit when l_name is null;
      l_name := ltrim(l_name, ':');
      if length(l_name) > 0 then
        if l_has then l_out := l_out || ','; end if;
        l_out := l_out || '"' || l_name || '":"' || c_q
                       || ' || :' || l_name || ' || '
                       || c_q || '"';
        l_has := true;
      end if;
      l_idx := l_idx + 1;
    end loop;

    l_out := l_out || '}' || c_q;
    return l_out;
  end build_binds_expr;


  procedure query_helper(
    p_query        in  clob,
    p_binds        in  clob     default null,
    p_doc_name     in  varchar2 default 'My export',
    p_format       in  varchar2 default 'KMZ',
    p_inline_binds in  varchar2 default null,
    p_bind_mode    in  varchar2 default 'QUERY',
    p_columns      out clob,
    p_snippet      out clob,
    p_query_clob   out clob,
    p_status       out varchar2
  ) is
    l_c            integer;
    l_cols         number;
    l_desc         dbms_sql.desc_tab3;
    l_bobj         json_object_t;
    l_bkeys        json_key_list;
    l_q            clob;
    l_engine_csv   varchar2(4000);
    l_inline_csv   varchar2(4000);
    l_inline_src   varchar2(20);     -- 'explicit' or 'auto'
    l_mode         varchar2(10);     -- 'QUERY' | 'JSON'
    l_binds_expr   clob;              -- PL/SQL expression for p_source_binds in the snippet
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
          l_engine_csv := case when l_engine_csv is null then upper(l_bkeys(i))
                               else l_engine_csv || ',' || upper(l_bkeys(i)) end;
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

    -- Effective inline-bind list: explicit override > auto-detect (all :NAME
    -- placeholders in the query minus anything already declared as an engine
    -- bind via p_binds JSON). Anything inline becomes
    --   q'<o>prefix<c>' || :NAME || q'<o>suffix<c>'
    -- so the CALLING session (e.g. APEX) resolves it before the query is stored.
    if p_inline_binds is not null and trim(p_inline_binds) is not null then
      l_inline_csv := p_inline_binds;
      l_inline_src := 'explicit';
    else
      l_inline_csv := detect_binds(p_query, l_engine_csv);
      l_inline_src := 'auto';
    end if;

    -- bind mode: where do inline binds get baked in?
    l_mode := upper(coalesce(p_bind_mode, 'QUERY'));
    if l_mode not in ('QUERY', 'JSON') then l_mode := 'QUERY'; end if;

    if l_engine_csv is not null then
      p_status := p_status || '; engine binds: ' || l_engine_csv;
    end if;
    if l_inline_csv is not null then
      p_status := p_status || '; inline binds (' || l_inline_src || ', mode=' || l_mode || '): ' || l_inline_csv;
    end if;

    -- l_q  : the source_query CLOB assignment text
    -- l_binds_expr : the PL/SQL expression for p_source_binds in the snippet (NULL = omit)
    if l_mode = 'JSON' and l_inline_csv is not null then
      -- Path B: query keeps :NAME; values go into source_binds via concat
      l_q          := qstring(p_query);
      l_binds_expr := build_binds_expr(p_binds, l_inline_csv);
    else
      -- Path A (default): inline values into source_query via concat
      if l_inline_csv is not null then
        l_q := qstring_inline(p_query, l_inline_csv);
      else
        l_q := qstring(p_query);
      end if;
      if p_binds is not null and dbms_lob.getlength(p_binds) > 0 then
        l_binds_expr := qstring(p_binds);
      else
        l_binds_expr := null;
      end if;
    end if;

    p_query_clob := 'l_query clob := ' || l_q || ';';

    p_snippet := p_snippet
              || 'declare'                                                                              || chr(10)
              || '  l_job number;'                                                                       || chr(10)
              || 'begin'                                                                                 || chr(10);
    if l_inline_csv is not null then
      if l_mode = 'JSON' then
        p_snippet := p_snippet
                  || '  -- Inline binds (' || l_inline_csv || ') are added to source_binds at submit time' || chr(10)
                  || '  -- (resolved by THIS session, e.g. APEX page items; the engine binds them at run time).' || chr(10);
      else
        p_snippet := p_snippet
                  || '  -- Inline binds (' || l_inline_csv || ') are resolved by THIS session' || chr(10)
                  || '  -- (e.g. APEX page items) BEFORE the query is stored on the job.'      || chr(10);
      end if;
    end if;
    p_snippet := p_snippet
              || '  l_job := pck_kml_job_api.create_job_from_query('                                     || chr(10)
              || '    p_document_name => ''' || replace(nvl(p_doc_name,'My export'),'''','''''') || ''',' || chr(10)
              || '    p_output_format => ''' || nvl(upper(p_format),'KMZ') || ''','                      || chr(10);
    if l_binds_expr is not null then
      p_snippet := p_snippet
                || '    p_source_binds  => ' || l_binds_expr || ',' || chr(10);
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


  function kml_to_rgb(p_kml in varchar2) return varchar2 is
    l varchar2(8) := lower(trim(p_kml));
  begin
    if l is null or length(l) <> 8 then return null; end if;
    -- aabbggrr -> #rrggbb
    return '#' || substr(l, 7, 2) || substr(l, 5, 2) || substr(l, 3, 2);
  exception when others then return null;
  end kml_to_rgb;


  function kml_alpha(p_kml in varchar2) return number is
    l varchar2(8) := trim(p_kml);
  begin
    if l is null or length(l) <> 8 then return null; end if;
    return to_number(substr(l, 1, 2), 'xx');
  exception when others then return null;
  end kml_alpha;


  procedure style_outputs(
    p_geojson       in  clob     default null,
    p_name          in  varchar2 default null,
    p_folder_name   in  varchar2 default null,
    p_line_color    in  varchar2 default null,
    p_line_width    in  number   default null,
    p_poly_color    in  varchar2 default null,
    p_poly_alpha    in  number   default 128,
    p_poly_fill     in  varchar2 default 'Y',
    p_poly_outline  in  varchar2 default 'Y',
    p_label_color   in  varchar2 default null,
    p_label_scale   in  number   default null,
    p_icon_href     in  varchar2 default null,
    p_icon_scale    in  number   default null,
    p_altitude_mode in  varchar2 default null,
    p_extrude       in  varchar2 default 'N',
    p_tessellate    in  varchar2 default 'N',
    p_extended_data in  clob     default null,
    p_snippet       out clob,
    p_kml_style     out clob
  ) is
    l_line  varchar2(6) := upper(ltrim(p_line_color,  '#'));
    l_poly  varchar2(6) := upper(ltrim(p_poly_color,  '#'));
    l_label varchar2(6) := upper(ltrim(p_label_color, '#'));

    function num(p_n in number) return varchar2 is   -- '.' decimal, no group sep
    begin
      return rtrim(rtrim(to_char(p_n, 'FM9999990.0999'), '0'), '.');
    end;
  begin
    --------------------------------------------------------------------- snippet
    p_snippet := 'l_a := pck_kml_job_api.add_asset('                                  || chr(10)
              || '         p_job_id           => l_job,'                              || chr(10);
    if p_geojson is not null and dbms_lob.getlength(p_geojson) > 0 then
      p_snippet := p_snippet
              || '         p_geometry_geojson => ' || qstring(p_geojson) || ','       || chr(10);
    end if;
    if p_name is not null then
      p_snippet := p_snippet
              || '         p_name             => ''' || replace(p_name,'''','''''') || ''','  || chr(10);
    end if;
    if p_folder_name is not null then
      p_snippet := p_snippet
              || '         p_folder_name      => ''' || replace(p_folder_name,'''','''''') || ''','  || chr(10);
    end if;
    if length(l_line) = 6 then
      p_snippet := p_snippet
              || '         p_line_color       => pck_kml_engine.rgba_to_kml(''' || l_line || '''),'  || chr(10);
    end if;
    if p_line_width is not null then
      p_snippet := p_snippet
              || '         p_line_width       => ' || num(p_line_width) || ','        || chr(10);
    end if;
    if length(l_poly) = 6 then
      p_snippet := p_snippet
              || '         p_poly_color       => pck_kml_engine.rgba_to_kml(''' || l_poly || ''', ' || nvl(p_poly_alpha,128) || '),'  || chr(10)
              || '         p_poly_fill        => ''' || nvl(p_poly_fill,'Y') || ''','     || chr(10)
              || '         p_poly_outline     => ''' || nvl(p_poly_outline,'Y') || ''',' || chr(10);
    end if;
    if length(l_label) = 6 then
      p_snippet := p_snippet
              || '         p_label_color      => pck_kml_engine.rgba_to_kml(''' || l_label || '''),' || chr(10);
    end if;
    if p_label_scale is not null then
      p_snippet := p_snippet
              || '         p_label_scale      => ' || num(p_label_scale) || ','        || chr(10);
    end if;
    if p_icon_href is not null then
      p_snippet := p_snippet
              || '         p_icon_href        => ''' || replace(p_icon_href,'''','''''') || ''','  || chr(10);
    end if;
    if p_icon_scale is not null then
      p_snippet := p_snippet
              || '         p_icon_scale       => ' || num(p_icon_scale) || ','         || chr(10);
    end if;
    if p_altitude_mode is not null then
      p_snippet := p_snippet
              || '         p_altitude_mode    => ''' || p_altitude_mode || ''','       || chr(10);
    end if;
    if nvl(p_extrude,'N') = 'Y' then
      p_snippet := p_snippet || '         p_extrude          => ''Y'','              || chr(10);
    end if;
    if nvl(p_tessellate,'N') = 'Y' then
      p_snippet := p_snippet || '         p_tessellate       => ''Y'','              || chr(10);
    end if;
    if p_extended_data is not null and dbms_lob.getlength(p_extended_data) > 0 then
      p_snippet := p_snippet
              || '         p_extended_data    => ' || qstring(p_extended_data) || ','   || chr(10);
    end if;
    -- trim the trailing ",\n" and close the call
    p_snippet := rtrim(p_snippet, ',' || chr(10)) || ');';

    ------------------------------------------------------------------- KML style
    p_kml_style := '<Style>' || chr(10);
    if length(l_line) = 6 or p_line_width is not null then
      p_kml_style := p_kml_style || '  <LineStyle>';
      if length(l_line) = 6 then
        p_kml_style := p_kml_style || '<color>' || pck_kml_engine.rgba_to_kml(l_line) || '</color>';
      end if;
      if p_line_width is not null then
        p_kml_style := p_kml_style || '<width>' || num(p_line_width) || '</width>';
      end if;
      p_kml_style := p_kml_style || '</LineStyle>' || chr(10);
    end if;
    if length(l_poly) = 6 then
      p_kml_style := p_kml_style || '  <PolyStyle>'
                  || '<color>' || pck_kml_engine.rgba_to_kml(l_poly, nvl(p_poly_alpha,128)) || '</color>'
                  || '<fill>'    || case when nvl(p_poly_fill,'Y')    = 'Y' then '1' else '0' end || '</fill>'
                  || '<outline>' || case when nvl(p_poly_outline,'Y') = 'Y' then '1' else '0' end || '</outline>'
                  || '</PolyStyle>' || chr(10);
    end if;
    if length(l_label) = 6 or p_label_scale is not null then
      p_kml_style := p_kml_style || '  <LabelStyle>';
      if length(l_label) = 6 then
        p_kml_style := p_kml_style || '<color>' || pck_kml_engine.rgba_to_kml(l_label) || '</color>';
      end if;
      if p_label_scale is not null then
        p_kml_style := p_kml_style || '<scale>' || num(p_label_scale) || '</scale>';
      end if;
      p_kml_style := p_kml_style || '</LabelStyle>' || chr(10);
    end if;
    if p_icon_href is not null or p_icon_scale is not null then
      p_kml_style := p_kml_style || '  <IconStyle>';
      if p_icon_scale is not null then
        p_kml_style := p_kml_style || '<scale>' || num(p_icon_scale) || '</scale>';
      end if;
      if p_icon_href is not null then
        p_kml_style := p_kml_style || '<Icon><href>' || p_icon_href || '</href></Icon>';
      end if;
      p_kml_style := p_kml_style || '</IconStyle>' || chr(10);
    end if;
    p_kml_style := p_kml_style || '</Style>';
  end style_outputs;


  -- Build one GeoJSON Feature (geometry + KMLeon-contract properties). Colors are
  -- expected ALREADY as KML aabbggrr (the caller converts when needed).
  function feature_obj(
    p_geom in clob, p_name in varchar2, p_folder in varchar2,
    p_line in varchar2, p_lw in number, p_poly in varchar2,
    p_fill in varchar2, p_outline in varchar2, p_label in varchar2, p_lscale in number,
    p_icon in varchar2, p_iscale in number, p_alt in varchar2, p_extr in varchar2, p_tess in varchar2,
    p_ext in clob default null
  ) return json_object_t is
    l_f    json_object_t := json_object_t();
    l_p    json_object_t := json_object_t();
    l_eo   json_object_t;
    l_keys json_key_list;
  begin
    l_f.put('type', 'Feature');
    begin
      l_f.put('geometry', json_object_t.parse(p_geom));
    exception when others then
      l_f.put('geometry', json_object_t());
    end;
    if p_name    is not null then l_p.put('NAME', p_name); end if;
    if p_folder  is not null then l_p.put('FOLDER_NAME', p_folder); end if;
    if p_line    is not null then l_p.put('LINE_COLOR', p_line); end if;
    if p_lw      is not null then l_p.put('LINE_WIDTH', p_lw); end if;
    if p_poly    is not null then l_p.put('POLY_COLOR', p_poly); end if;
    if p_fill    is not null then l_p.put('POLY_FILL', p_fill); end if;
    if p_outline is not null then l_p.put('POLY_OUTLINE', p_outline); end if;
    if p_label   is not null then l_p.put('LABEL_COLOR', p_label); end if;
    if p_lscale  is not null then l_p.put('LABEL_SCALE', p_lscale); end if;
    if p_icon    is not null then l_p.put('ICON_HREF', p_icon); end if;
    if p_iscale  is not null then l_p.put('ICON_SCALE', p_iscale); end if;
    if p_alt     is not null then l_p.put('ALTITUDE_MODE', p_alt); end if;
    if nvl(p_extr,'N') = 'Y'  then l_p.put('EXTRUDE', 'Y'); end if;
    if nvl(p_tess,'N') = 'Y'  then l_p.put('TESSELLATE', 'Y'); end if;
    -- merge extended_data keys flat into properties (they map to ExtendedData on
    -- ingestion because they are not reserved names; nested EXTENDED_DATA would not).
    if p_ext is not null and dbms_lob.getlength(p_ext) > 0 then
      begin
        l_eo   := json_object_t.parse(p_ext);
        l_keys := l_eo.get_keys;
        for i in 1 .. l_keys.count loop
          l_p.put(l_keys(i), l_eo.get(l_keys(i)));
        end loop;
      exception when others then null;   -- malformed JSON: skip
      end;
    end if;
    l_f.put('properties', l_p);
    return l_f;
  end feature_obj;


  procedure rest_outputs(
    p_job_id        in  number   default null,
    p_geojson       in  clob     default null,
    p_name          in  varchar2 default null,
    p_folder_name   in  varchar2 default null,
    p_line_color    in  varchar2 default null,
    p_line_width    in  number   default null,
    p_poly_color    in  varchar2 default null,
    p_poly_alpha    in  number   default 128,
    p_poly_fill     in  varchar2 default 'Y',
    p_poly_outline  in  varchar2 default 'Y',
    p_label_color   in  varchar2 default null,
    p_label_scale   in  number   default null,
    p_icon_href     in  varchar2 default null,
    p_icon_scale    in  number   default null,
    p_altitude_mode in  varchar2 default null,
    p_extrude       in  varchar2 default 'N',
    p_tessellate    in  varchar2 default 'N',
    p_extended_data in  clob     default null,
    p_base_url      in  varchar2 default 'https://HOST/ords/SCHEMA/kmleon/v1',
    p_asset_rest    out clob,
    p_job_rest      out clob
  ) is
    c_base   varchar2(400)  := rtrim(p_base_url, '/');
    l_line   varchar2(8) := case when p_line_color  is not null then pck_kml_engine.rgba_to_kml(ltrim(p_line_color,'#')) end;
    l_poly   varchar2(8) := case when p_poly_color  is not null then pck_kml_engine.rgba_to_kml(ltrim(p_poly_color,'#'), nvl(p_poly_alpha,128)) end;
    l_label  varchar2(8) := case when p_label_color is not null then pck_kml_engine.rgba_to_kml(ltrim(p_label_color,'#')) end;
    l_jobref varchar2(40) := case when p_job_id is not null then to_char(p_job_id) else '{job_id}' end;
    l_feat   json_object_t;
    l_fc     json_object_t;
    l_arr    json_array_t;
    l_doc    kml_jobs.document_name%type;
    l_fmt    kml_jobs.output_format%type;
    l_geom   clob;
  begin
    ------------------------------------------------------------ single asset
    if p_geojson is not null and dbms_lob.getlength(p_geojson) > 0 then
      l_feat := feature_obj(p_geojson, p_name, p_folder_name, l_line, p_line_width, l_poly,
                            p_poly_fill, p_poly_outline, l_label, p_label_scale,
                            p_icon_href, p_icon_scale, p_altitude_mode, p_extrude, p_tessellate,
                            p_extended_data);
      p_asset_rest :=
        '# Add THIS feature (geometry + style) to job ' || l_jobref || ' via REST' || chr(10) ||
        'curl -X POST "' || c_base || '/jobs/' || l_jobref || '/features" \' || chr(10) ||
        '  -H "Content-Type: application/json" \' || chr(10) ||
        '  -d ''' || l_feat.to_clob || '''';
    else
      p_asset_rest := '# draw a geometry first';
    end if;

    ------------------------------------------------------------ whole job
    if p_job_id is not null then
      begin
        select document_name, output_format into l_doc, l_fmt from kml_jobs where job_id = p_job_id;
      exception when no_data_found then
        l_doc := 'My export'; l_fmt := 'KMZ';
      end;
      l_fc  := json_object_t();
      l_fc.put('type', 'FeatureCollection');
      l_arr := json_array_t();
      for r in (select * from kml_job_assets where job_id = p_job_id order by display_order, asset_id) loop
        l_geom := nvl(r.geometry_geojson,
                      case when r.geometry_sdo is not null then sdo_util.to_geojson(r.geometry_sdo) end);
        if l_geom is not null then
          l_arr.append(feature_obj(l_geom, r.name, r.folder_name, r.line_color, r.line_width, r.poly_color,
                                   r.poly_fill, r.poly_outline, r.label_color, r.label_scale,
                                   r.icon_href, r.icon_scale, r.altitude_mode, r.extrude, r.tessellate,
                                   r.extended_data));
        end if;
      end loop;
      l_fc.put('features', l_arr);

      p_job_rest :=
        '# Re-create job #' || p_job_id || ' (' || l_doc || ') entirely over REST.' || chr(10) ||
        '# 1) create the job  ->  returns {"job_id":N,...}; use N as NEW_JOB_ID below' || chr(10) ||
        'curl -X POST "' || c_base || '/jobs" \' || chr(10) ||
        '  -H "Content-Type: application/json" \' || chr(10) ||
        '  -d ''{"document_name":"' || replace(l_doc, '"', '\"') || '","output_format":"' || l_fmt || '"}''' || chr(10) || chr(10) ||
        '# 2) add all ' || l_arr.get_size || ' feature(s)  (replace NEW_JOB_ID)' || chr(10) ||
        'curl -X POST "' || c_base || '/jobs/NEW_JOB_ID/features" \' || chr(10) ||
        '  -H "Content-Type: application/json" \' || chr(10) ||
        '  -d ''' || l_fc.to_clob || '''' || chr(10) || chr(10) ||
        '# 3) run it now' || chr(10) ||
        'curl -X POST "' || c_base || '/jobs/NEW_JOB_ID/run"' || chr(10) || chr(10) ||
        '# 4) download the result' || chr(10) ||
        'curl "' || c_base || '/jobs/NEW_JOB_ID/result" -o export.' || lower(l_fmt);
    else
      p_job_rest := '# select a job above to generate its full REST script';
    end if;
  exception
    when others then
      if p_asset_rest is null then p_asset_rest := '# error: ' || sqlerrm; end if;
      if p_job_rest   is null then p_job_rest   := '# error: ' || sqlerrm; end if;
  end rest_outputs;

end pck_kmleon_tools;
/
