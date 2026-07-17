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
  -- Default: the KML_CONFIG key LOG_THRESHOLD (read lazily once per session via
  -- dynamic SQL -- no compile-time dependency), else INFO. Calling set_threshold
  -- explicitly overrides the config for this session.
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

  -- Housekeeping: delete log rows older than p_older_than_days (null or <= 0 = no-op,
  -- retention disabled). Returns rows deleted. Does NOT commit (the caller owns the
  -- transaction). The retention value is passed in (by PCK_KML_MAINTENANCE) so this
  -- package keeps depending on nothing -- no cycle with PCK_KML_CONFIG_DML.
  function purge(p_older_than_days in number) return pls_integer;
end pck_kml_log;
/

create or replace package body pck_kml_log
as
  g_threshold pls_integer := 3;   -- default: INFO
  g_loaded    boolean     := false;   -- config threshold read for this session?

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
    g_loaded    := true;   -- explicit call wins over the config default
  end set_threshold;

  -- Lazily pick up KML_CONFIG.LOG_THRESHOLD once per session. Dynamic SQL keeps
  -- this package free of a compile-time dependency on PCK_KML_CONFIG_DML (which
  -- installs after it); before the config package exists this quietly no-ops.
  procedure load_threshold is
    l_level varchar2(10);
  begin
    g_loaded := true;   -- set FIRST: a log call from inside get_string must not recurse here
    execute immediate
      'begin :l := pck_kml_config_dml.get_string(''LOG_THRESHOLD''); end;'
      using out l_level;
    if l_level is not null then
      g_threshold := severity(l_level);
    end if;
  exception
    when others then
      null;   -- config not installed / not readable: keep the default
  end load_threshold;

  -- The single physical writer. Autonomous so logs survive caller rollback.
  procedure write_log(
    p_level   in varchar2,
    p_package in varchar2,
    p_routine in varchar2,
    p_message in clob,
    p_job_id  in number
  ) is
    pragma autonomous_transaction;
    -- normalize unknown levels to INFO so the check constraint can never make a
    -- message vanish silently (severity() already treats unknown as INFO).
    l_level varchar2(10) := case when upper(p_level) in (c_error, c_warn, c_info, c_debug)
                                 then upper(p_level) else c_info end;
  begin
    insert into kml_log (log_level, package_name, routine_name, job_id, message,
                         created_at, created_by, updated_at, updated_by)
    values (l_level, p_package, p_routine, p_job_id, p_message,
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
    if not g_loaded then
      load_threshold;
    end if;
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

  function purge(p_older_than_days in number) return pls_integer is
    l_rows pls_integer;
  begin
    if p_older_than_days is null or p_older_than_days <= 0 then
      return 0;   -- retention disabled
    end if;
    delete from kml_log
     where created_at < systimestamp - numtodsinterval(p_older_than_days, 'DAY');
    return sql%rowcount;
  end purge;
end pck_kml_log;
/
