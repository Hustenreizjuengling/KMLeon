--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_LOG  (central logging + DML access for KML_LOG)
--------------------------------------------------------------------------------
-- Package-wide logging used by every other KMLeon package. Entries are written
-- in an autonomous transaction so they persist even when the caller rolls back.
-- This package is the *only* code that writes KML_LOG.
--
-- Placeholder note: routing/retention (e.g. forwarding ERROR to a monitoring
-- system) belongs in WRITE_LOG -- extend there.
--------------------------------------------------------------------------------

create or replace package pck_kml_log
  authid definer
as
  c_error constant varchar2(10) := 'ERROR';
  c_warn  constant varchar2(10) := 'WARN';
  c_info  constant varchar2(10) := 'INFO';
  c_debug constant varchar2(10) := 'DEBUG';

  -- Only messages at or above this severity are persisted (ERROR=1 .. DEBUG=4).
  procedure set_threshold(p_level in varchar2);

  procedure log(
    p_level   in varchar2,
    p_package in varchar2,
    p_routine in varchar2,
    p_message in clob,
    p_job_id  in number default null
  );

  procedure error(p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null);
  procedure warn (p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null);
  procedure info (p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null);
  procedure debug(p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null);
end pck_kml_log;
/

create or replace package body pck_kml_log
as
  g_threshold pls_integer := 3;   -- default: INFO

  function severity(p_level in varchar2) return pls_integer is
  begin
    return case upper(p_level)
             when c_error then 1
             when c_warn  then 2
             when c_info  then 3
             when c_debug then 4
             else 3
           end;
  end severity;

  procedure set_threshold(p_level in varchar2) is
  begin
    g_threshold := severity(p_level);
  end set_threshold;

  -- The single physical writer. Autonomous so logs survive caller rollback.
  procedure write_log(
    p_level   in varchar2,
    p_package in varchar2,
    p_routine in varchar2,
    p_message in clob,
    p_job_id  in number
  ) is
    pragma autonomous_transaction;
  begin
    insert into kml_log (log_level, package_name, routine_name, job_id, message,
                         created_at, created_by, updated_at, updated_by)
    values (upper(p_level), p_package, p_routine, p_job_id, p_message,
            systimestamp, user, systimestamp, user);
    commit;
  exception
    when others then
      rollback;   -- never let logging break the caller
  end write_log;

  procedure log(
    p_level   in varchar2,
    p_package in varchar2,
    p_routine in varchar2,
    p_message in clob,
    p_job_id  in number default null
  ) is
  begin
    if severity(p_level) <= g_threshold then
      write_log(p_level, p_package, p_routine, p_message, p_job_id);
    end if;
  end log;

  procedure error(p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null) is
  begin log(c_error, p_package, p_routine, p_message, p_job_id); end;

  procedure warn(p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null) is
  begin log(c_warn, p_package, p_routine, p_message, p_job_id); end;

  procedure info(p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null) is
  begin log(c_info, p_package, p_routine, p_message, p_job_id); end;

  procedure debug(p_package in varchar2, p_routine in varchar2, p_message in clob, p_job_id in number default null) is
  begin log(c_debug, p_package, p_routine, p_message, p_job_id); end;
end pck_kml_log;
/
