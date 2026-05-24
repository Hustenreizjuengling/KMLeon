--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_JOBS_DML  (sole DML access to KML_JOBS)
--------------------------------------------------------------------------------
-- Every write to KML_JOBS goes through here. Audit columns are auto-stamped when
-- passed NULL. These routines do NOT commit (the caller owns the transaction);
-- logging is emitted via PCK_KML_LOG (which commits autonomously).
--------------------------------------------------------------------------------

create or replace package pck_kml_jobs_dml
  authid definer
as
  c_pkg constant varchar2(30) := 'PCK_KML_JOBS_DML';

  function ins(
    p_document_name   in varchar2,
    p_description     in varchar2 default null,
    p_output_format   in varchar2 default 'KMZ',
    p_output_filename in varchar2 default null,
    p_priority        in number   default 100,
    p_user_tab        in varchar2 default null,
    p_user_id         in varchar2 default null,
    p_notify_email    in varchar2 default null,
    p_status          in varchar2 default 'DRAFT',
    p_source_type     in varchar2 default 'ASSETS',
    p_source_mode     in varchar2 default 'STREAM',
    p_source_query    in clob     default null,
    p_source_binds    in clob     default null,
    p_created_by      in varchar2 default null
  ) return number;

  procedure set_status(p_job_id in number, p_status in varchar2);
  procedure set_running(p_job_id in number);
  procedure set_notified(p_job_id in number);   -- stamp notified_at

  procedure set_completed(
    p_job_id in number,
    p_kml    in clob   default null,
    p_kmz    in blob   default null,
    p_size   in number,
    p_count  in number
  );

  procedure set_failed(p_job_id in number, p_error in varchar2);

  -- Set CANCELLED only if still DRAFT/PENDING; returns rows affected.
  function cancel(p_job_id in number) return pls_integer;

  function get(p_job_id in number) return kml_jobs%rowtype;
  procedure del(p_job_id in number);

  -- Delete jobs (+assets via FK) older than p_older_than_days. p_statuses is a
  -- comma list, but only terminal statuses (COMPLETED/FAILED/CANCELLED) are ever
  -- removed regardless of what is passed. Returns rows deleted.
  function purge(
    p_statuses        in varchar2 default 'COMPLETED,CANCELLED',
    p_older_than_days in number   default 30
  ) return pls_integer;

  -- Back-compat: purge all terminal statuses (delegates to purge).
  procedure purge_finished(p_older_than_days in number default 30);
end pck_kml_jobs_dml;
/

create or replace package body pck_kml_jobs_dml
as

  function ins(
    p_document_name   in varchar2,
    p_description     in varchar2 default null,
    p_output_format   in varchar2 default 'KMZ',
    p_output_filename in varchar2 default null,
    p_priority        in number   default 100,
    p_user_tab        in varchar2 default null,
    p_user_id         in varchar2 default null,
    p_notify_email    in varchar2 default null,
    p_status          in varchar2 default 'DRAFT',
    p_source_type     in varchar2 default 'ASSETS',
    p_source_mode     in varchar2 default 'STREAM',
    p_source_query    in clob     default null,
    p_source_binds    in clob     default null,
    p_created_by      in varchar2 default null
  ) return number
  is
    l_id  number;
    l_now timestamp    := systimestamp;
    l_who varchar2(128) := nvl(p_created_by, user);
  begin
    if upper(p_source_type) = 'QUERY'
       and (p_source_query is null or dbms_lob.getlength(p_source_query) = 0)
    then
      raise_application_error(-20812, 'QUERY job requires a non-empty source_query.');
    end if;

    insert into kml_jobs (
      document_name, description, output_format, output_filename, priority,
      user_tab, user_id, notify_email, status, source_type, source_mode, source_query, source_binds,
      created_at, created_by, updated_at, updated_by
    ) values (
      p_document_name, p_description, upper(p_output_format), p_output_filename, p_priority,
      p_user_tab, p_user_id, p_notify_email, p_status, upper(p_source_type), upper(p_source_mode),
      p_source_query, p_source_binds,
      l_now, l_who, l_now, l_who
    ) returning job_id into l_id;

    pck_kml_log.info(c_pkg, 'ins', 'created job "' || p_document_name || '"', l_id);
    pck_kml_config_dml.touch_metric('METRIC_LAST_JOB_CREATED_AT');   -- best-effort
    return l_id;
  end ins;


  procedure set_status(p_job_id in number, p_status in varchar2) is
  begin
    update kml_jobs
       set status     = p_status,
           updated_at = systimestamp,
           updated_by = user
     where job_id = p_job_id;
    pck_kml_log.debug(c_pkg, 'set_status', 'status -> ' || p_status, p_job_id);
  end set_status;


  procedure set_running(p_job_id in number) is
  begin
    update kml_jobs
       set status        = 'RUNNING',
           started_at    = systimestamp,
           error_message = null,
           updated_at    = systimestamp,
           updated_by    = user
     where job_id = p_job_id;
    pck_kml_log.info(c_pkg, 'set_running', 'job started', p_job_id);
  end set_running;


  procedure set_notified(p_job_id in number) is
  begin
    update kml_jobs
       set notified_at = systimestamp,
           updated_at  = systimestamp,
           updated_by  = user
     where job_id = p_job_id;
    pck_kml_log.debug(c_pkg, 'set_notified', 'notified_at stamped', p_job_id);
  end set_notified;


  procedure set_completed(
    p_job_id in number,
    p_kml    in clob   default null,
    p_kmz    in blob   default null,
    p_size   in number,
    p_count  in number
  ) is
  begin
    update kml_jobs
       set status            = 'COMPLETED',
           finished_at       = systimestamp,
           result_kml        = p_kml,
           result_kmz        = p_kmz,
           result_size_bytes = p_size,
           asset_count       = p_count,
           error_message     = null,
           updated_at        = systimestamp,
           updated_by        = user
     where job_id = p_job_id;
    pck_kml_log.info(c_pkg, 'set_completed',
                     'completed (' || p_count || ' assets, ' || p_size || ' bytes)', p_job_id);
    pck_kml_config_dml.touch_metric('METRIC_LAST_JOB_COMPLETED_AT');   -- best-effort
  end set_completed;


  procedure set_failed(p_job_id in number, p_error in varchar2) is
  begin
    update kml_jobs
       set status        = 'FAILED',
           finished_at    = systimestamp,
           error_message  = substr(p_error, 1, 4000),
           updated_at     = systimestamp,
           updated_by     = user
     where job_id = p_job_id;
    pck_kml_log.error(c_pkg, 'set_failed', p_error, p_job_id);
    pck_kml_config_dml.touch_metric('METRIC_LAST_JOB_FAILED_AT');   -- best-effort
  end set_failed;


  function cancel(p_job_id in number) return pls_integer is
    l_rows pls_integer;
  begin
    update kml_jobs
       set status      = 'CANCELLED',
           finished_at = systimestamp,
           updated_at  = systimestamp,
           updated_by  = user
     where job_id = p_job_id
       and status in ('DRAFT', 'PENDING');
    l_rows := sql%rowcount;   -- capture before any other SQL (logger INSERT resets sql%rowcount)
    pck_kml_log.info(c_pkg, 'cancel', 'cancelled rows=' || l_rows, p_job_id);
    if l_rows > 0 then
      pck_kml_config_dml.touch_metric('METRIC_LAST_JOB_CANCELLED_AT');   -- best-effort
    end if;
    return l_rows;
  end cancel;


  function get(p_job_id in number) return kml_jobs%rowtype is
    l_row kml_jobs%rowtype;
  begin
    select * into l_row from kml_jobs where job_id = p_job_id;
    return l_row;
  exception
    when no_data_found then
      raise_application_error(-20813, 'KML job not found: job_id=' || p_job_id);
  end get;


  procedure del(p_job_id in number) is
  begin
    delete from kml_jobs where job_id = p_job_id;  -- assets cascade
    pck_kml_log.info(c_pkg, 'del', 'deleted job', p_job_id);
  end del;


  function purge(
    p_statuses        in varchar2 default 'COMPLETED,CANCELLED',
    p_older_than_days in number   default 30
  ) return pls_integer is
    l_norm varchar2(200) := upper(replace(p_statuses, ' '));  -- e.g. ',COMPLETED,CANCELLED,'
    l_rows pls_integer;
  begin
    delete from kml_jobs
     where status in ('COMPLETED', 'FAILED', 'CANCELLED')                 -- terminal-only guard
       and instr(',' || l_norm || ',', ',' || status || ',') > 0          -- configured subset
       and finished_at < systimestamp - numtodsinterval(p_older_than_days, 'DAY');
    l_rows := sql%rowcount;   -- capture before any other SQL (logger INSERT resets sql%rowcount)
    pck_kml_log.info(c_pkg, 'purge',
      'purged rows=' || l_rows || ' statuses=' || l_norm || ' older_than_days=' || p_older_than_days);
    return l_rows;
  end purge;


  procedure purge_finished(p_older_than_days in number default 30) is
    l_void pls_integer;
  begin
    l_void := purge('COMPLETED,FAILED,CANCELLED', p_older_than_days);
  end purge_finished;

end pck_kml_jobs_dml;
/
