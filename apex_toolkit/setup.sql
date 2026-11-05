--------------------------------------------------------------------------------
-- KMLeon Toolkit :: one-shot setup
--------------------------------------------------------------------------------
-- Run as the schema that owns the KMLeon objects:
--   sqlplus kmleon/****@db @setup.sql
--   -- or in SQLcl: sql kmleon/****@db @setup.sql
--
-- Installs the toolkit's helper package (PCK_KMLEON_TOOLS) used by the APEX
-- pages. Re-runnable (CREATE OR REPLACE) and safe on production: it creates no
-- data. Sample jobs for a demo/dev instance live in setup_samples.sql.
--------------------------------------------------------------------------------
set define off
set serveroutput on size unlimited
set echo off
whenever sqlerror continue

prompt -- package PCK_KMLEON_TOOLS (lives alongside the core KMLeon packages)
@@../sql/packages/pck_kmleon_tools.sql
show errors
