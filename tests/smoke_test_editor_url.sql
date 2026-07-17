--------------------------------------------------------------------------------
-- KMLeon :: smoke test - public_editor_url (REST editor-link building block)
--------------------------------------------------------------------------------
-- Asserts PCK_KMLEON_TOOLS.public_editor_url:
--   * with the correct key: returns a URL that targets the v2 editor page and
--     carries job_id + access_key, WITHOUT a leaking bootstrap session id;
--   * in a plain SQL session (no web context) the URL is relative ('/...');
--     over REST the same function prefixes scheme://host/context from the request;
--   * with a wrong key: raises -20813 (indistinguishable from "not found").
-- Requires APEX (apex_session/apex_page) -- like the toolkit itself.
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job number;
  l_key varchar2(64);
  l_url varchar2(4000);
begin
  l_job := pck_kml_job_api.create_job(
             p_document_name => 'Editor-URL smoke test',
             p_output_format => 'KML');
  l_key := pck_kml_job_api.get_access_key(l_job);
  commit;

  --- correct key: URL shape ----------------------------------------------------
  l_url := pck_kmleon_tools.public_editor_url(l_job, l_key);
  dbms_output.put_line('editor url : ' || l_url);
  if instr(l_url, 'public-editor-v2') = 0
     or instr(l_url, 'p200_job_id=' || l_job) = 0
     or instr(l_url, 'p200_access_key=' || l_key) = 0 then
    raise_application_error(-20999, 'editor-url smoke FAILED: URL is missing page/id/key');
  end if;
  if regexp_like(l_url, '(\?|&)session=') then
    raise_application_error(-20999, 'editor-url smoke FAILED: bootstrap session id leaked into the URL');
  end if;
  if substr(l_url, 1, 1) != '/' and substr(l_url, 1, 4) != 'http' then
    raise_application_error(-20999, 'editor-url smoke FAILED: URL is neither relative nor absolute');
  end if;

  --- wrong key: same error as "not found" -------------------------------------
  begin
    l_url := pck_kmleon_tools.public_editor_url(l_job, 'wrongkey');
    raise_application_error(-20999, 'editor-url smoke FAILED: wrong key was accepted');
  exception when others then
    if sqlcode != -20813 then raise; end if;
  end;
  dbms_output.put_line('wrong key  : rejected with -20813 (as designed)');

  pck_kml_jobs_dml.del(l_job);   -- cleanup
  commit;
  dbms_output.put_line('editor-url smoke test OK (job cleaned up)');
end;
/
