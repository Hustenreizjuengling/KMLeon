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
--   POST   jobs                 create an ASSETS job   (JSON body)        -> {job_id,status,access_key}
--   GET    jobs/{id}            job status + metadata
--   POST   jobs/{id}/features   add features from a GeoJSON FeatureCollection (JSON body)
--   POST   jobs/{id}/submit     DRAFT -> PENDING (needs KMLEON_DISPATCHER enabled; it is
--                               created DISABLED by default -- use /run for on-demand)
--   POST   jobs/{id}/run        run synchronously now
--   POST   jobs/{id}/cancel     cancel a DRAFT/PENDING job
--   GET    jobs/{id}/result     download the KMZ/KML
--
-- SECURITY (READ THIS)
--   * The QUERY job source (arbitrary SQL run as this schema) is intentionally
--     NOT exposed here -- create QUERY jobs only from inside the database.
--   * The module is shipped PUBLISHED and UNPROTECTED on purpose, so you can adapt
--     authentication to your own environment. These endpoints WRITE data and run
--     jobs -- before any non-trivial use, protect them: uncomment the "PROTECT THE
--     MODULE" block at the bottom (ORDS privilege), and/or front ORDS with
--     OAuth2 / first-party auth, HTTPS, and (optionally) CORS via
--     ORDS.SET_MODULE_ORIGINS_ALLOWED. Do not expose a public write API as-is.
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
          :status_code := 201;
          owa_util.mime_header('application/json');
          htp.p('{"job_id":' || l_id || ',"status":"DRAFT","access_key":"' || l_key || '"}');
        end if;
      exception
        when others then        -- malformed JSON body etc.
          :status_code := 400;
          owa_util.mime_header('application/json');
          htp.p('{"error":"invalid request body"}');
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
      exception when no_data_found then
        :status_code := 404;
        owa_util.mime_header('application/json');
        htp.p('{"error":"job not found"}');
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
        htp.p('{"job_id":' || :id || ',"features_added":' || l_n || '}');
      exception
        when others then
          if sqlcode in (-2291, -20813) then        -- job not found (FK / lookup)
            :status_code := 404;
            owa_util.mime_header('application/json');
            htp.p('{"error":"job not found"}');
          elsif sqlcode in (-20821, -1722, -1858, -40441) then  -- bad GeoJSON / bad id
            :status_code := 400;
            owa_util.mime_header('application/json');
            htp.p('{"error":"invalid request (bad job id or GeoJSON)"}');
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
        htp.p('{"job_id":' || :id || ',"status":"PENDING"}');
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
        htp.p('{"job_id":' || :id || ',"status":"' || l_status || '"}');
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
        htp.p('{"job_id":' || :id || ',"status":"CANCELLED"}');
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
       where job_id = to_number(:id)
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
 where t.uri_template like 'jobs%'
 order by t.uri_template, h.method;

--------------------------------------------------------------------------------
-- OPTIONAL: PROTECT THE MODULE with an ORDS privilege (recommended).
-- After this, callers need a mapped role (OAuth2 client / first-party user).
--------------------------------------------------------------------------------
-- begin
--   ords.define_privilege(
--     p_privilege_name => 'kmleon.access',
--     p_roles          => ords_t_strings('KMLeon User'),
--     p_patterns       => ords_t_strings('/kmleon/v1/*'),
--     p_label          => 'KMLeon API',
--     p_description     => 'Access to the KMLeon REST API');
--   commit;
-- end;
-- /
--------------------------------------------------------------------------------
-- To remove everything again:
--   begin ords.delete_module(p_module_name => 'kmleon.v1'); commit; end;
--------------------------------------------------------------------------------
