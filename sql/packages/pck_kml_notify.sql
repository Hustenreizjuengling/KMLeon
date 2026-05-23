--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_NOTIFY  (job completion e-mail -- generic + extensible)
--------------------------------------------------------------------------------
-- Prepares a notification e-mail (subject, body, and the result file as an
-- attachment) for a finished job and hands it to a mail sender.
--
-- DESIGNED TO BE CUSTOMIZED. Out of the box it does everything it can on its own
-- (build the message, attach the result, pick the recipient from KML_JOBS.notify_email)
-- and then DOES NOT actually send anything. Two small hooks in the body are the
-- only places you edit -- both have safe defaults and are marked "CUSTOMIZE HERE":
--   * resolve_recipient(user_tab, user_id) -> map a creator to an e-mail address
--   * send_mail(t_mail)                    -> call APEX_MAIL or your own wrapper
--
-- Recipient precedence: KML_JOBS.notify_email (explicit, e.g. from REST) wins;
-- otherwise resolve_recipient(user_tab, user_id) is consulted.
--
-- Called best-effort from PCK_KML_ENGINE.run_job after a job finishes; a failure
-- here is logged and never affects the job. Writes notified_at via the DML package.
--------------------------------------------------------------------------------

create or replace package pck_kml_notify
  authid definer
as
  c_pkg constant varchar2(30) := 'PCK_KML_NOTIFY';

  -- Results larger than this are emailed without the attachment (a note is added
  -- to the body instead). Tune to your mail system's limits.
  gc_max_attach_bytes constant number := 10 * 1024 * 1024;   -- 10 MB

  -- A fully prepared message. recipient/attachment may be NULL.
  type t_mail is record (
    recipient  varchar2(4000),
    subject    varchar2(400),
    body       clob,
    attachment blob,
    filename   varchar2(260),
    mime_type  varchar2(100)
  );

  -- Build the message for a job (generic; always works, sends nothing).
  -- p_event is 'COMPLETED' or 'FAILED'.
  function prepare(p_job_id in number, p_event in varchar2 default 'COMPLETED') return t_mail;

  -- Prepare + hand off to the mail sender; stamps notified_at. Best-effort + commits.
  procedure notify(p_job_id in number, p_event in varchar2 default 'COMPLETED');

end pck_kml_notify;
/

create or replace package body pck_kml_notify
as

  -- UTF-8 CLOB -> BLOB (self-contained so this package depends only on the DML
  -- package and the logger -- not on the engine).
  function clob_to_blob(p_clob in clob) return blob is
    l_blob         blob;
    l_dest_offset  integer := 1;
    l_src_offset   integer := 1;
    l_lang_context integer := dbms_lob.default_lang_ctx;
    l_warning      integer;
  begin
    if p_clob is null then
      return null;
    end if;
    dbms_lob.createtemporary(l_blob, true);
    dbms_lob.converttoblob(l_blob, p_clob, dbms_lob.lobmaxsize, l_dest_offset,
                           l_src_offset, nls_charset_id('AL32UTF8'), l_lang_context, l_warning);
    return l_blob;
  end clob_to_blob;


  ------------------------------------------------------------------------------
  -- CUSTOMIZE HERE (1/2): map a job's creator to an e-mail address.
  ------------------------------------------------------------------------------
  -- Default: return NULL. Jobs then get e-mailed only if KML_JOBS.notify_email is
  -- set (e.g. supplied via REST). Implement this to resolve in-database users:
  --
  --   function resolve_recipient(p_user_tab in varchar2, p_user_id in varchar2)
  --     return varchar2 is
  --     l_email varchar2(400);
  --   begin
  --     if p_user_tab = 'APP_USERS' then
  --       select email into l_email from app_users where id = p_user_id;
  --       return l_email;
  --     end if;
  --     return null;
  --   exception when no_data_found then return null;
  --   end;
  ------------------------------------------------------------------------------
  function resolve_recipient(p_user_tab in varchar2, p_user_id in varchar2) return varchar2 is
  begin
    return null;   -- no in-database resolution by default
  end resolve_recipient;


  ------------------------------------------------------------------------------
  -- CUSTOMIZE HERE (2/2): actually send the prepared mail.
  ------------------------------------------------------------------------------
  -- Default: send nothing (just log that a mail was prepared). Replace the body
  -- with APEX_MAIL or a call to your existing mail wrapper, e.g.:
  --
  --   declare l_id number;
  --   begin
  --     l_id := apex_mail.send(p_to => p_mail.recipient, p_subj => p_mail.subject,
  --                            p_body => p_mail.body);
  --     if p_mail.attachment is not null then
  --       apex_mail.add_attachment(p_mail_id => l_id, p_attachment => p_mail.attachment,
  --                                p_filename => p_mail.filename, p_mime_type => p_mail.mime_type);
  --     end if;
  --     apex_mail.push_queue;
  --   end;
  --
  -- ...or:  my_mail_pkg.send(p_to => p_mail.recipient, p_subject => p_mail.subject,
  --                          p_body => p_mail.body, p_blob => p_mail.attachment, ...);
  ------------------------------------------------------------------------------
  procedure send_mail(p_mail in t_mail) is
  begin
    pck_kml_log.info(c_pkg, 'send_mail',
      'no mail sender configured -- prepared mail to ' || p_mail.recipient
      || ' (attachment=' ||
      case when p_mail.attachment is null then 'none'
           else dbms_lob.getlength(p_mail.attachment) || ' bytes' end || ')');
  end send_mail;


  function prepare(p_job_id in number, p_event in varchar2 default 'COMPLETED') return t_mail is
    l_job      kml_jobs%rowtype;
    l_mail     t_mail;
    l_doc      varchar2(400);
    l_fmt      varchar2(3);
    l_size     number;
    l_attached boolean := false;
  begin
    l_job := pck_kml_jobs_dml.get(p_job_id);
    l_doc := nvl(l_job.document_name, 'KMLeon export');

    -- recipient: explicit notify_email wins, else the resolver hook
    l_mail.recipient := nvl(l_job.notify_email,
                            resolve_recipient(l_job.user_tab, l_job.user_id));

    if upper(p_event) = 'FAILED' then
      l_mail.subject := 'KMLeon: "' || l_doc || '" failed';
      l_mail.body := 'Your KMLeon export "' || l_doc || '" failed.' || chr(10) || chr(10)
                  || 'Job:   ' || p_job_id || chr(10)
                  || 'Error: ' || substr(l_job.error_message, 1, 2000);
      return l_mail;
    end if;

    -- COMPLETED: build the attachment from the result (within the size limit)
    l_fmt  := upper(l_job.output_format);
    l_size := nvl(l_job.result_size_bytes, 0);
    l_mail.filename  := nvl(l_job.output_filename, 'kmleon_' || p_job_id)
                     || case when l_fmt = 'KMZ' then '.kmz' else '.kml' end;
    l_mail.mime_type := case when l_fmt = 'KMZ' then 'application/vnd.google-earth.kmz'
                             else 'application/vnd.google-earth.kml+xml' end;

    if l_size > 0 and l_size <= gc_max_attach_bytes then
      l_mail.attachment := case when l_fmt = 'KMZ' then l_job.result_kmz
                                else clob_to_blob(l_job.result_kml) end;
      l_attached := l_mail.attachment is not null;
    end if;

    l_mail.body := 'Your KMLeon export "' || l_doc || '" is ready.' || chr(10) || chr(10)
                || 'Job:    ' || p_job_id || chr(10)
                || 'Format: ' || l_fmt || chr(10)
                || 'Assets: ' || nvl(l_job.asset_count, 0) || chr(10)
                || 'Size:   ' || l_size || ' bytes' || chr(10)
                || case when l_attached then ''
                        else chr(10) || '(The file was not attached -- download it from the application.)' || chr(10)
                   end;
    return l_mail;
  end prepare;


  procedure notify(p_job_id in number, p_event in varchar2 default 'COMPLETED') is
    l_mail t_mail;
  begin
    l_mail := prepare(p_job_id, p_event);

    if l_mail.recipient is null then
      pck_kml_log.info(c_pkg, 'notify',
        'no recipient (set notify_email or implement resolve_recipient); skipping', p_job_id);
      return;
    end if;

    send_mail(l_mail);                       -- your sender / APEX_MAIL (no-op by default)
    pck_kml_jobs_dml.set_notified(p_job_id);
    commit;
    pck_kml_log.info(c_pkg, 'notify',
      'notification handed to sender for ' || l_mail.recipient, p_job_id);
  exception
    when others then
      rollback;
      -- best-effort: a notification problem must never affect the job itself
      pck_kml_log.error(c_pkg, 'notify',
        sqlerrm || chr(10) || dbms_utility.format_error_backtrace, p_job_id);
  end notify;

end pck_kml_notify;
/
