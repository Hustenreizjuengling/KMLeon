--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_CONFIG_DML  (sole DML access to KML_CONFIG)
--------------------------------------------------------------------------------
-- Typed key/value accessor + the only writer of KML_CONFIG. Reads are plain
-- SELECTs with a caller-supplied default (never raise on a missing key). Writes
-- upsert through a single private routine and auto-stamp the audit columns.
-- These routines do NOT commit (the caller owns the transaction); logging is
-- emitted via PCK_KML_LOG. Depends only on PCK_KML_LOG -> install before
-- PCK_KML_JOBS_DML (which calls touch_metric).
--------------------------------------------------------------------------------

create or replace package pck_kml_config_dml
  authid definer
as
  c_pkg constant varchar2(30) := 'PCK_KML_CONFIG_DML';

  --- typed reads (return p_default when the key is absent) ---------------------
  function get_string   (p_key in varchar2, p_default in varchar2  default null) return varchar2;
  function get_number   (p_key in varchar2, p_default in number    default null) return number;
  function get_timestamp(p_key in varchar2, p_default in timestamp default null) return timestamp;
  function get_boolean  (p_key in varchar2, p_default in boolean   default false) return boolean;

  --- typed writes (upsert; category defaults to SETTING) ----------------------
  procedure set_string   (p_key in varchar2, p_value in varchar2,  p_category in varchar2 default 'SETTING', p_description in varchar2 default null);
  procedure set_number   (p_key in varchar2, p_value in number,    p_category in varchar2 default 'SETTING', p_description in varchar2 default null);
  procedure set_timestamp(p_key in varchar2, p_value in timestamp, p_category in varchar2 default 'SETTING', p_description in varchar2 default null);
  procedure set_boolean  (p_key in varchar2, p_value in boolean,   p_category in varchar2 default 'SETTING', p_description in varchar2 default null);

  --- metric helpers (best-effort: never raise to the caller) ------------------
  procedure touch_metric(p_key in varchar2);          -- stamp value_timestamp = systimestamp
  procedure bump_metric (p_key in varchar2, p_by in number default 1);  -- increment value_number

  --- idempotent seed of the default SETTING + METRIC rows (re-runnable) -------
  procedure init_defaults;
end pck_kml_config_dml;
/

create or replace package body pck_kml_config_dml
as

  --- single physical upsert; every write funnels through here -----------------
  procedure upsert(
    p_key         in varchar2,
    p_category    in varchar2,
    p_data_type   in varchar2,
    p_vs          in varchar2,
    p_vn          in number,
    p_vt          in timestamp,
    p_description in varchar2
  ) is
  begin
    merge into kml_config t
    using (select p_key as k from dual) s
       on (t.config_key = s.k)
    when matched then update set
        t.data_type       = p_data_type,
        t.value_string    = p_vs,
        t.value_number    = p_vn,
        t.value_timestamp  = p_vt,
        t.category        = nvl(p_category, t.category),
        t.description     = nvl(p_description, t.description),
        t.updated_at      = systimestamp,
        t.updated_by      = user
    when not matched then insert
        (config_key, category, data_type, value_string, value_number, value_timestamp,
         description, created_at, created_by, updated_at, updated_by)
      values
        (p_key, nvl(p_category, 'SETTING'), p_data_type, p_vs, p_vn, p_vt,
         p_description, systimestamp, user, systimestamp, user);
  end upsert;


  --- insert-if-absent; preserves user edits across reinstall ------------------
  procedure seed(
    p_key         in varchar2,
    p_category    in varchar2,
    p_data_type   in varchar2,
    p_vs          in varchar2,
    p_vn          in number,
    p_vt          in timestamp,
    p_description in varchar2
  ) is
  begin
    merge into kml_config t
    using (select p_key as k from dual) s
       on (t.config_key = s.k)
    when not matched then insert
        (config_key, category, data_type, value_string, value_number, value_timestamp,
         description, created_at, created_by, updated_at, updated_by)
      values
        (p_key, p_category, p_data_type, p_vs, p_vn, p_vt,
         p_description, systimestamp, user, systimestamp, user);
  end seed;


  function get_string(p_key in varchar2, p_default in varchar2 default null) return varchar2 is
    l_val kml_config.value_string%type;
  begin
    select value_string into l_val from kml_config where config_key = p_key;
    return l_val;
  exception
    when no_data_found then return p_default;
  end get_string;


  function get_number(p_key in varchar2, p_default in number default null) return number is
    l_val kml_config.value_number%type;
  begin
    select value_number into l_val from kml_config where config_key = p_key;
    return l_val;
  exception
    when no_data_found then return p_default;
  end get_number;


  function get_timestamp(p_key in varchar2, p_default in timestamp default null) return timestamp is
    l_val kml_config.value_timestamp%type;
  begin
    select value_timestamp into l_val from kml_config where config_key = p_key;
    return l_val;
  exception
    when no_data_found then return p_default;
  end get_timestamp;


  function get_boolean(p_key in varchar2, p_default in boolean default false) return boolean is
    l_val kml_config.value_string%type;
  begin
    select value_string into l_val from kml_config where config_key = p_key;
    if l_val is null then          -- row exists but unset: honour the caller's default
      return p_default;
    end if;
    return upper(l_val) in ('Y', 'YES', 'TRUE', '1');
  exception
    when no_data_found then return p_default;
  end get_boolean;


  procedure set_string(p_key in varchar2, p_value in varchar2, p_category in varchar2 default 'SETTING', p_description in varchar2 default null) is
  begin
    upsert(p_key, p_category, 'STRING', p_value, null, null, p_description);
    pck_kml_log.debug(c_pkg, 'set_string', p_key || ' = ' || p_value);
  end set_string;


  procedure set_number(p_key in varchar2, p_value in number, p_category in varchar2 default 'SETTING', p_description in varchar2 default null) is
  begin
    upsert(p_key, p_category, 'NUMBER', null, p_value, null, p_description);
    pck_kml_log.debug(c_pkg, 'set_number', p_key || ' = ' || to_char(p_value));
  end set_number;


  procedure set_timestamp(p_key in varchar2, p_value in timestamp, p_category in varchar2 default 'SETTING', p_description in varchar2 default null) is
  begin
    upsert(p_key, p_category, 'TIMESTAMP', null, null, p_value, p_description);
    pck_kml_log.debug(c_pkg, 'set_timestamp', p_key || ' set');
  end set_timestamp;


  procedure set_boolean(p_key in varchar2, p_value in boolean, p_category in varchar2 default 'SETTING', p_description in varchar2 default null) is
  begin
    upsert(p_key, p_category, 'BOOLEAN', case when p_value then 'Y' else 'N' end, null, null, p_description);
    pck_kml_log.debug(c_pkg, 'set_boolean', p_key || ' = ' || case when p_value then 'Y' else 'N' end);
  end set_boolean;


  procedure touch_metric(p_key in varchar2) is
  begin
    upsert(p_key, 'METRIC', 'TIMESTAMP', null, null, systimestamp, null);
  exception
    when others then
      -- metrics must never break the calling job transaction
      pck_kml_log.warn(c_pkg, 'touch_metric', 'metric ' || p_key || ' skipped: ' || sqlerrm);
  end touch_metric;


  procedure bump_metric(p_key in varchar2, p_by in number default 1) is
    l_cur number;
  begin
    l_cur := get_number(p_key, 0);
    upsert(p_key, 'METRIC', 'NUMBER', null, nvl(l_cur, 0) + p_by, null, null);
  exception
    when others then
      pck_kml_log.warn(c_pkg, 'bump_metric', 'metric ' || p_key || ' skipped: ' || sqlerrm);
  end bump_metric;


  procedure init_defaults is
  begin
    --- SETTINGs (general behaviour) --------------------------------------------
    seed('DELETE_ASSETS_AFTER_SUCCESS', 'SETTING', 'BOOLEAN', 'Y', null, null,
         'After a job builds successfully, delete its stored KML_JOB_ASSETS rows (frees space; the result stays on the job).');

    --- SETTINGs (the cleanup / maintenance job) --------------------------------
    seed('CLEANUP_ENABLED',        'SETTING', 'BOOLEAN', 'N',  null, null,
         'Master switch for the KMLEON_MAINTENANCE cleanup job.');
    seed('CLEANUP_INTERVAL',       'SETTING', 'STRING',  'FREQ=DAILY;BYHOUR=3', null, null,
         'DBMS_SCHEDULER calendar string for how often cleanup runs.');
    seed('CLEANUP_RETENTION_DAYS', 'SETTING', 'NUMBER',  null, 30, null,
         'Only jobs finished more than this many days ago are eligible for cleanup.');
    seed('CLEANUP_STATUSES',       'SETTING', 'STRING',  'COMPLETED,CANCELLED', null, null,
         'Comma-separated terminal statuses the cleanup job deletes (terminal only).');

    --- METRICs (auto-maintained; start NULL) -----------------------------------
    seed('METRIC_LAST_JOB_CREATED_AT',   'METRIC', 'TIMESTAMP', null, null, null, 'When a job was last created.');
    seed('METRIC_LAST_JOB_COMPLETED_AT', 'METRIC', 'TIMESTAMP', null, null, null, 'When a job last completed.');
    seed('METRIC_LAST_JOB_FAILED_AT',    'METRIC', 'TIMESTAMP', null, null, null, 'When a job last failed.');
    seed('METRIC_LAST_JOB_CANCELLED_AT', 'METRIC', 'TIMESTAMP', null, null, null, 'When a job was last cancelled.');
    seed('METRIC_LAST_CLEANUP_AT',       'METRIC', 'TIMESTAMP', null, null, null, 'When the cleanup job last ran.');
    seed('METRIC_LAST_CLEANUP_DELETED',  'METRIC', 'NUMBER',    null, null, null, 'Rows deleted by the last cleanup run.');

    pck_kml_log.info(c_pkg, 'init_defaults', 'default config rows seeded');
  end init_defaults;

end pck_kml_config_dml;
/
