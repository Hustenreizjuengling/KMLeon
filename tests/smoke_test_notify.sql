--------------------------------------------------------------------------------
-- KMLeon :: smoke test - notifications (prepare + NOTIFY_SENDER routing)
--------------------------------------------------------------------------------
-- * prepare(): subject/body/attachment for COMPLETED and FAILED
-- * NOTIFY_SENDER = NONE: nothing sent, notified_at still stamped, job intact
-- * NOTIFY_SENDER = APEX_MAIL without NOTIFY_FROM: clean failure, job intact
-- * NOTIFY_SENDER = APEX_MAIL with NOTIFY_FROM (only when APEX is installed AND
--   the setting TEST_ALLOW_MAIL = Y opts in): one row more in APEX_MAIL_QUEUE for
--   the recipient (left in the queue; the instance's mail job / an admin purges
--   it -- there is no public delete API). Never enable on production.
-- Settings are restored at the end.
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job   number;
  l_mail  pck_kml_notify.t_mail;
  l_row   kml_jobs%rowtype;
  l_prev_sender varchar2(40)  := pck_kml_config_dml.get_string('NOTIFY_SENDER');
  l_prev_from   varchar2(400) := pck_kml_config_dml.get_string('NOTIFY_FROM');
  l_prev_ws     varchar2(255) := pck_kml_config_dml.get_string('NOTIFY_APEX_WORKSPACE');
  l_apex  pls_integer;
  l_q0    pls_integer;
  l_q1    pls_integer;
  l_ws    varchar2(255);

  procedure must(p_cond in boolean, p_what in varchar2) is
  begin
    if not p_cond then
      raise_application_error(-20999, 'notify smoke FAILED: ' || p_what);
    end if;
    dbms_output.put_line('OK   ' || p_what);
  end must;

  function new_job return number is
    l number;
    a number;
  begin
    l := pck_kml_job_api.create_job(p_document_name => 'Notify smoke', p_output_format => 'KML',
                                    p_notify_email => 'kmleon-smoke@example.com');
    a := pck_kml_job_api.add_asset(p_job_id => l,
           p_geometry_geojson => to_clob('{"type":"Point","coordinates":[13.405,52.52]}'), p_name => 'Berlin');
    commit;
    return l;
  end new_job;
begin
  --- NONE -----------------------------------------------------------------------
  pck_kml_config_dml.set_string('NOTIFY_SENDER', 'NONE');
  commit;
  l_job := new_job;
  pck_kml_job_api.run_now(l_job);
  l_row := pck_kml_jobs_dml.get(l_job);
  must(l_row.status = 'COMPLETED', 'NONE: job completed');
  must(l_row.notified_at is not null, 'NONE: notified_at stamped (mail prepared, not sent)');
  l_mail := pck_kml_notify.prepare(l_job, 'COMPLETED');
  must(l_mail.recipient = 'kmleon-smoke@example.com', 'prepare: recipient from notify_email');
  must(l_mail.subject like '%Notify smoke%', 'prepare: subject names the document');
  must(l_mail.attachment is not null and l_mail.filename = 'kmleon_' || l_job || '.kml'
       and l_mail.mime_type = 'application/vnd.google-earth.kml+xml', 'prepare: KML attachment + filename');
  if dbms_lob.istemporary(l_mail.attachment) = 1 then dbms_lob.freetemporary(l_mail.attachment); end if;
  pck_kml_jobs_dml.set_failed(l_job, 'simulated failure');
  commit;
  l_mail := pck_kml_notify.prepare(l_job, 'FAILED');
  must(l_mail.attachment is null and l_mail.body like '%simulated failure%', 'prepare: FAILED mail carries the error, no attachment');
  pck_kml_jobs_dml.del(l_job);
  commit;

  --- APEX_MAIL misconfigured: must never hurt the job ----------------------------
  pck_kml_config_dml.set_string('NOTIFY_SENDER', 'APEX_MAIL');
  pck_kml_config_dml.set_string('NOTIFY_FROM', null);
  commit;
  l_job := new_job;
  pck_kml_job_api.run_now(l_job);
  l_row := pck_kml_jobs_dml.get(l_job);
  must(l_row.status = 'COMPLETED', 'APEX_MAIL without NOTIFY_FROM: job still COMPLETED');
  must(l_row.notified_at is null, 'APEX_MAIL without NOTIFY_FROM: not marked as notified');
  pck_kml_jobs_dml.del(l_job);
  commit;

  --- APEX_MAIL real queueing (only with APEX and when explicitly allowed) ----------
  -- opt-in: this queues a REAL mail (to kmleon-smoke@example.com) in APEX_MAIL_QUEUE,
  -- which an instance with SMTP will try to deliver. Enable on test instances with
  --   exec pck_kml_config_dml.set_boolean('TEST_ALLOW_MAIL', true); commit;
  select count(*) into l_apex from all_objects where object_name = 'APEX_MAIL' and object_type = 'SYNONYM';
  if not pck_kml_config_dml.get_boolean('TEST_ALLOW_MAIL', false) then
    dbms_output.put_line('skip APEX_MAIL queue check (set TEST_ALLOW_MAIL = Y on a test instance to enable)');
  elsif l_apex > 0 then
    begin
      execute immediate 'select workspace_name from apex_workspace_schemas where schema = user and rownum = 1' into l_ws;
    exception when others then l_ws := null;
    end;
    if l_ws is not null then
      pck_kml_config_dml.set_string('NOTIFY_FROM', 'kmleon@example.com');
      pck_kml_config_dml.set_string('NOTIFY_APEX_WORKSPACE', l_ws);
      commit;
      execute immediate 'select count(*) from apex_mail_queue where mail_to = ''kmleon-smoke@example.com''' into l_q0;
      l_job := new_job;
      pck_kml_job_api.run_now(l_job);
      l_row := pck_kml_jobs_dml.get(l_job);
      execute immediate 'select count(*) from apex_mail_queue where mail_to = ''kmleon-smoke@example.com''' into l_q1;
      must(l_row.status = 'COMPLETED' and l_row.notified_at is not null, 'APEX_MAIL: job completed and notified');
      must(l_q1 = l_q0 + 1, 'APEX_MAIL: one mail queued in APEX_MAIL_QUEUE (' || l_q0 || ' -> ' || l_q1 || ')');
      pck_kml_jobs_dml.del(l_job);
      commit;
    else
      dbms_output.put_line('skip APEX_MAIL queue check (schema is not an APEX workspace schema)');
    end if;
  else
    dbms_output.put_line('skip APEX_MAIL queue check (APEX not installed)');
  end if;

  --- restore ----------------------------------------------------------------------
  pck_kml_config_dml.set_string('NOTIFY_SENDER', nvl(l_prev_sender, 'NONE'));
  pck_kml_config_dml.set_string('NOTIFY_FROM', l_prev_from);
  pck_kml_config_dml.set_string('NOTIFY_APEX_WORKSPACE', l_prev_ws);
  commit;
  dbms_output.put_line('notify smoke test OK (jobs cleaned up, settings restored)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_notify')]'; exception when others then null; end;
exception
  when others then
    pck_kml_config_dml.set_string('NOTIFY_SENDER', nvl(l_prev_sender, 'NONE'));
    pck_kml_config_dml.set_string('NOTIFY_FROM', l_prev_from);
    pck_kml_config_dml.set_string('NOTIFY_APEX_WORKSPACE', l_prev_ws);
    commit;
    raise;
end;
/
