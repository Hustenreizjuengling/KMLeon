--------------------------------------------------------------------------------
-- KMLeon :: table KML_CONFIG
--------------------------------------------------------------------------------
-- Typed key/value store for both SETTINGs (user-configured, e.g. the cleanup job)
-- and METRICs (auto-maintained operational values, e.g. when a job last failed).
-- Exactly one value_* column is populated per row, indicated by data_type.
-- All DML goes through PCK_KML_CONFIG_DML; never write this table directly.
--------------------------------------------------------------------------------

create table kml_config (
  config_key       varchar2(100)  not null
                      constraint kml_config_pk primary key,
  category         varchar2(20)   default 'SETTING' not null,  -- SETTING | METRIC
  data_type        varchar2(20)   not null,                    -- STRING | NUMBER | TIMESTAMP | BOOLEAN
  value_string     varchar2(4000),
  value_number     number,
  value_timestamp  timestamp,
  description      varchar2(400),
  --- audit (auto-populated by PCK_KML_CONFIG_DML when passed NULL) -------------
  created_at       timestamp      default systimestamp,
  created_by       varchar2(128)  default user,
  updated_at       timestamp      default systimestamp,
  updated_by       varchar2(128)  default user,
  constraint kml_config_category_ck
    check (category in ('SETTING','METRIC')),
  constraint kml_config_dtype_ck
    check (data_type in ('STRING','NUMBER','TIMESTAMP','BOOLEAN'))
);

-- The Settings page / metric dashboards scan by category.
create index kml_config_category_ix on kml_config (category);

comment on table  kml_config                 is 'KMLeon typed key/value config. SETTING rows are user-configured (e.g. the cleanup job); METRIC rows are auto-maintained operational values. DML only via PCK_KML_CONFIG_DML.';
comment on column kml_config.config_key      is 'Unique key, e.g. CLEANUP_ENABLED or METRIC_LAST_JOB_FAILED_AT.';
comment on column kml_config.category        is 'SETTING (configured) or METRIC (auto-maintained).';
comment on column kml_config.data_type       is 'Which value_* column carries the value: STRING/NUMBER/TIMESTAMP/BOOLEAN (BOOLEAN stored in value_string as Y/N).';
comment on column kml_config.value_string    is 'Value when data_type is STRING or BOOLEAN (Y/N).';
comment on column kml_config.value_number    is 'Value when data_type is NUMBER.';
comment on column kml_config.value_timestamp is 'Value when data_type is TIMESTAMP.';
comment on column kml_config.description      is 'Human-readable purpose of the key.';
