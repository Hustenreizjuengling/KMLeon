--------------------------------------------------------------------------------
-- KMLeon :: ORDS REST API  (run in APEX SQL Workshop)
--------------------------------------------------------------------------------
-- Creates the KMLeon REST module/templates/handlers programmatically via the
-- ORDS PL/SQL API -- no manual clicking in the RESTful Services UI.
--
-- HOW TO RUN
--   APEX > SQL Workshop > SQL Scripts > Upload/paste this file > Run.
--   (Or paste just the main BEGIN ... END; block into SQL Workshop > SQL Commands.)
--   Run as the schema that owns the KMLeon objects.
--
-- RESULTING ENDPOINTS  (base: /ords/<schema-alias>/kmleon/v1/)
--   GET    jobs                 list recent jobs
--   POST   jobs                 create an ASSETS job   (JSON body)
--                               -> {job_id,status,access_key,editor_url}
--   GET    jobs/{id}            job status + metadata (404 unknown, 400 non-numeric id)
--   GET    jobs/{id}/editor-link?key=<access_key>
--                               full public-editor deep link for the job
--                               -> {job_id,editor_url}. The key is REQUIRED and
--                               must match (comes from the POST /jobs response),
--                               so this endpoint cannot be used to harvest keys.
--                               The URL is NOT configured anywhere: APEX builds
--                               it (APEX_SESSION + APEX_PAGE.GET_URL) and the
--                               host/context root come from THIS request.
--   POST   jobs/{id}/features   add features from a GeoJSON FeatureCollection (JSON body)
--   POST   jobs/{id}/submit     DRAFT -> PENDING (needs KMLEON_DISPATCHER enabled; it is
--                               created DISABLED by default -- use /run for on-demand)
--   POST   jobs/{id}/run        run synchronously now
--   POST   jobs/{id}/cancel     cancel a DRAFT/PENDING job
--   DELETE jobs/{id}            delete a job (+assets/result); 409 while PENDING/RUNNING
--   GET    jobs/{id}/result     download the KMZ/KML
--   GET    version              {"version":"<KMLeon release>","api":"v1"}
--
-- SECURITY (READ THIS)
--   * The QUERY job source (arbitrary SQL run as this schema) is intentionally
--     NOT exposed here -- create QUERY jobs only from inside the database.
--   * The module is shipped PUBLISHED and UNPROTECTED on purpose, so you can adapt
--     authentication to your own environment. These endpoints WRITE data and run
--     jobs -- before any non-trivial use, protect them: run 020_rest_protect.sql
--     (ORDS privilege + OAuth2 client-credentials client, re-runnable), front ORDS
--     with HTTPS, and (optionally) restrict CORS via ORDS.SET_MODULE_ORIGINS_ALLOWED.
--     Do not expose a public write API as-is.
--------------------------------------------------------------------------------

set define off

--------------------------------------------------------------------------------
-- OPTIONAL: REST-enable this schema. APEX workspace schemas usually already are.
-- Uncomment ONLY if /ords/<alias>/ is not yet reachable. NOTE: this sets the URL
-- alias and may change an existing mapping -- check first.
--------------------------------------------------------------------------------
-- begin
--   ords.enable_schema(
--     p_enabled             => true,
--     p_schema              => sys_context('userenv','current_schema'),
--     p_url_mapping_type    => 'BASE_PATH',
--     p_url_mapping_pattern => 'kml',          -- -> /ords/kml/kmleon/v1/...
--     p_auto_rest_auth      => false);
--   commit;
-- end;
-- /

--------------------------------------------------------------------------------
-- Define the module, templates and handlers (re-runnable).
--------------------------------------------------------------------------------
begin
  -- drop a previous version so this script can be re-run
  begin
    ords.delete_module(p_module_name => 'kmleon.v1');
  exception when others then null;
  end;

  ords.define_module(
    p_module_name    => 'kmleon.v1',
    p_base_path      => 'kmleon/v1/',
    p_items_per_page => 25,
    p_status         => 'PUBLISHED',
    p_comments       => 'KMLeon REST API');

  ----------------------------------------------------------------- jobs
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs');

  -- GET jobs : list recent jobs (auto-paginated JSON)
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs',
    p_method      => 'GET',
    p_source_type => ords.source_type_collection_feed,
    p_source      => q'~
      select job_id, document_name, status, output_format, source_type,
             asset_count, created_at, finished_at
        from kml_jobs
       order by job_id desc
    ~');

  -- POST jobs : create an ASSETS job from a JSON body
  ords.define_handler(
    p_module_name   => 'kmleon.v1',
    p_pattern       => 'jobs',
    p_method        => 'POST',
    p_source_type   => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source        => q'~
      declare
        l_in  json_object_t;
        l_doc varchar2(400);
        l_id  number;
        l_key varchar2(64);
        l_url varchar2(4000);
      begin
        l_in  := json_object_t.parse(:body_text);
        l_doc := l_in.get_string('document_name');
        if l_doc is null then
          :status_code := 400;
          owa_util.mime_header('application/json');
          htp.p('{"error":"document_name is required"}');
        else
          l_id := pck_kml_job_api.create_job(
                    p_document_name   => l_doc,
                    p_description     => l_in.get_string('description'),
                    p_output_format   => nvl(l_in.get_string('output_format'), 'KMZ'),
                    p_output_filename => l_in.get_string('output_filename'),
                    p_priority        => nvl(l_in.get_number('priority'), 100),
                    p_user_tab        => l_in.get_string('user_tab'),
                    p_user_id         => l_in.get_string('user_id'),
                    p_notify_email    => l_in.get_string('notify_email'));
          commit;
          l_key := pck_kml_job_api.get_access_key(l_id);
          -- best-effort: the ready-to-use public-editor deep link (built by APEX,
          -- host from this request); a URL problem must never fail the creation
          begin
            l_url := pck_kmleon_tools.public_editor_url(l_id, l_key);
          exception when others then
            l_url := null;
          end;
          declare
            l_out json_object_t := json_object_t();
          begin
            l_out.put('job_id', l_id);
            l_out.put('status', 'DRAFT');
            l_out.put('access_key', l_key);
            if l_url is not null then
              l_out.put('editor_url', l_url);
            end if;
            :status_code := 201;
            owa_util.mime_header('application/json');
            htp.p(l_out.to_clob);
          end;
        end if;
      exception
        when others then
          -- client errors only: malformed JSON (-40441), JSON type mismatch (-40xxx),
          -- value/number conversion, KMLeon validation (-208xx); anything else is a
          -- server fault and must surface as 500 with its real cause
          if sqlcode in (-1722, -6502, -1400, -2290, -12899)                -- conversion, NOT NULL, check constraint, too long
             or sqlcode in (-30625) or sqlcode between -40999 and -40000                            -- JSON parse / type errors
             or sqlcode between -20899 and -20800 then                        -- KMLeon validation
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p(json_object('error' value 'invalid request body', 'detail' value substr(sqlerrm, 1, 300)));
          else
            raise;
          end if;
      end;
    ~');

  ----------------------------------------------------------------- jobs/:id
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs/:id');

  -- GET jobs/:id : status + metadata
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs/:id',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~
      declare
        l_json clob;
      begin
        select json_object(
                 'job_id'            value job_id,
                 'document_name'     value document_name,
                 'status'            value status,
                 'output_format'     value output_format,
                 'source_type'       value source_type,
                 'asset_count'       value asset_count,
                 'result_size_bytes' value result_size_bytes,
                 'error_message'     value error_message,
                 'created_at'        value created_at,
                 'started_at'        value started_at,
                 'finished_at'       value finished_at
                 returning clob)
          into l_json
          from kml_jobs
         where job_id = to_number(:id);
        owa_util.mime_header('application/json');
        htp.p(l_json);
      exception
        when no_data_found then
          :status_code := 404;
          owa_util.mime_header('application/json');
          htp.p('{"error":"job not found"}');
        when invalid_number or value_error then   -- non-numeric :id (ORA-1722 / ORA-6502)
          :status_code := 400;
          owa_util.mime_header('application/json');
          htp.p('{"error":"invalid job id"}');
      end;
    ~');

  ----------------------------------------------------------------- jobs/:id/editor-link
  -- Full public-editor deep link for one job. ?key= is REQUIRED and must match
  -- the job's access_key (the caller has it from POST /jobs) -- wrong/missing
  -- key behaves exactly like an unknown job (404), so ids cannot be probed.
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs/:id/editor-link');
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs/:id/editor-link',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~
      declare
        l_url varchar2(4000);
      begin
        if :key is null then
          :status_code := 400;
          owa_util.mime_header('application/json');
          htp.p('{"error":"key query parameter is required"}');
        else
          l_url := pck_kmleon_tools.public_editor_url(to_number(:id), :key);
          declare
            l_out json_object_t := json_object_t();
          begin
            l_out.put('job_id', to_number(:id));
            l_out.put('editor_url', l_url);
            owa_util.mime_header('application/json');
            htp.p(l_out.to_clob);
          end;
        end if;
      exception
        when others then
          if sqlcode = -20813 then            -- job not found OR wrong key (deliberately identical)
            :status_code := 404;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job not found"}');
          elsif sqlcode = -1722 then          -- non-numeric :id
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p('{"error":"invalid job id"}');
          else
            raise;
          end if;
      end;
    ~');

  ----------------------------------------------------------------- jobs/:id/features
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs/:id/features');

  -- POST jobs/:id/features : ingest a GeoJSON FeatureCollection (body = raw GeoJSON)
  ords.define_handler(
    p_module_name   => 'kmleon.v1',
    p_pattern       => 'jobs/:id/features',
    p_method        => 'POST',
    p_source_type   => ords.source_type_plsql,
    p_mimes_allowed => 'application/json',
    p_source        => q'~
      declare
        l_n number;
      begin
        l_n := pck_kml_job_api.add_features_geojson(to_number(:id), :body_text);
        commit;
        owa_util.mime_header('application/json');
        htp.p('{"job_id":' || to_number(:id) || ',"features_added":' || l_n || '}');
      exception
        when others then
          if sqlcode in (-2291, -20813) then        -- job not found (FK / lookup)
            :status_code := 404;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job not found"}');
          elsif sqlcode in (-1722, -1858, -6502, -2290, -12899)
             or sqlcode in (-30625) or sqlcode between -40999 and -40000                            -- JSON parse / structure errors
             or sqlcode between -20899 and -20800 then                        -- bad GeoJSON / style validation
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p(json_object('error' value 'invalid request (bad job id or GeoJSON)', 'detail' value substr(sqlerrm, 1, 300)));
          else
            raise;
          end if;
      end;
    ~');

  ----------------------------------------------------------------- jobs/:id/submit
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs/:id/submit');
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs/:id/submit',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~
      begin
        pck_kml_job_api.submit_job(to_number(:id));
        owa_util.mime_header('application/json');
        htp.p('{"job_id":' || to_number(:id) || ',"status":"PENDING"}');
      exception
        when others then
          if sqlcode = -20810 then            -- not in DRAFT state
            :status_code := 409;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job cannot be submitted in its current state"}');
          elsif sqlcode = -20813 then         -- job not found
            :status_code := 404;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job not found"}');
          elsif sqlcode = -1722 then          -- non-numeric :id
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p('{"error":"invalid job id"}');
          else
            raise;
          end if;
      end;
    ~');

  ----------------------------------------------------------------- jobs/:id/run
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs/:id/run');
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs/:id/run',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~
      declare
        l_status varchar2(20);
      begin
        pck_kml_job_api.run_now(to_number(:id));
        l_status := pck_kml_job_api.get_status(to_number(:id));
        owa_util.mime_header('application/json');
        htp.p('{"job_id":' || to_number(:id) || ',"status":"' || l_status || '"}');
      exception
        when others then
          if sqlcode = -20813 then            -- job not found
            :status_code := 404;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job not found"}');
          elsif sqlcode = -1722 then          -- non-numeric :id
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p('{"error":"invalid job id"}');
          else
            raise;
          end if;
      end;
    ~');

  ----------------------------------------------------------------- jobs/:id/cancel
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs/:id/cancel');
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs/:id/cancel',
    p_method      => 'POST',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~
      begin
        pck_kml_job_api.cancel_job(to_number(:id));
        owa_util.mime_header('application/json');
        htp.p('{"job_id":' || to_number(:id) || ',"status":"CANCELLED"}');
      exception
        when others then
          if sqlcode = -20813 then            -- job not found
            :status_code := 404;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job not found"}');
          elsif sqlcode = -20811 then         -- not cancellable (running/finished)
            :status_code := 409;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job cannot be cancelled in its current state"}');
          elsif sqlcode = -1722 then          -- non-numeric :id
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p('{"error":"invalid job id"}');
          else
            raise;
          end if;
      end;
    ~');

  -- DELETE jobs/:id : remove a job with its assets and result
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs/:id',
    p_method      => 'DELETE',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~
      begin
        pck_kml_job_api.delete_job(to_number(:id));
        owa_util.mime_header('application/json');
        htp.p('{"job_id":' || to_number(:id) || ',"deleted":true}');
      exception
        when others then
          if sqlcode = -20813 then            -- job not found
            :status_code := 404;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job not found"}');
          elsif sqlcode = -20815 then         -- PENDING / RUNNING
            :status_code := 409;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job cannot be deleted while pending or running; cancel it first"}');
          elsif sqlcode = -1722 then          -- non-numeric :id
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p('{"error":"invalid job id"}');
          else
            raise;
          end if;
      end;
    ~');

  ----------------------------------------------------------------- version
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'version');
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'version',
    p_method      => 'GET',
    p_source_type => ords.source_type_plsql,
    p_source      => q'~
      declare
        l_out json_object_t := json_object_t();
      begin
        l_out.put('version', pck_kml_engine.version);
        l_out.put('installed', pck_kml_config_dml.get_string('KMLEON_VERSION'));
        l_out.put('api', 'v1');
        owa_util.mime_header('application/json');
        htp.p(l_out.to_clob);
      end;
    ~');

  ----------------------------------------------------------------- jobs/:id/result
  -- Download the generated KMZ/KML. Uses source_type_media (the documented pattern
  -- for GET binary/text downloads): the query returns the MIME type first and the
  -- LOB second; ORDS streams it and returns 404 automatically when no row matches.
  -- Only COMPLETED jobs match, so pending/failed/unknown ids yield 404.
  ords.define_template(p_module_name => 'kmleon.v1', p_pattern => 'jobs/:id/result');
  ords.define_handler(
    p_module_name => 'kmleon.v1',
    p_pattern     => 'jobs/:id/result',
    p_method      => 'GET',
    p_source_type => ords.source_type_media,
    p_source      => q'~
      select case when output_format = 'KMZ' then 'application/vnd.google-earth.kmz'
                  else 'application/vnd.google-earth.kml+xml' end as content_type,
             case when output_format = 'KMZ' then result_kmz
                  else pck_kml_engine.clob_to_blob(result_kml) end as media_resource
        from kml_jobs
       where job_id = to_number(:id default null on conversion error)   -- non-numeric id -> no row -> 404
         and status = 'COMPLETED'
    ~');

  commit;
end;
/

--------------------------------------------------------------------------------
-- Verify what was created.
--------------------------------------------------------------------------------
select t.uri_template, h.method, h.source_type
  from user_ords_templates t
  join user_ords_handlers  h on h.template_id = t.id
  join user_ords_modules   m on m.id = t.module_id
 where m.name = 'kmleon.v1'
 order by t.uri_template, h.method;

--------------------------------------------------------------------------------
-- PROTECT THE MODULE: see 020_rest_protect.sql (ORDS privilege + OAuth2 client).
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- To remove everything again:
--   begin ords.delete_module(p_module_name => 'kmleon.v1'); commit; end;
--------------------------------------------------------------------------------
