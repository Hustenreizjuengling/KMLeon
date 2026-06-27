--------------------------------------------------------------------------------
-- KMLeon :: smoke test - access_key + public-editor on-the-fly render
--------------------------------------------------------------------------------
-- Verifies: access_key is generated + unguessable + unique; get_access_key reads
-- it back; build_kml renders WITHOUT submitting the job or deleting its assets
-- (the public download path). Run after install.sql / update.sql.
--------------------------------------------------------------------------------
set serveroutput on size unlimited
set lines 200

declare
  l_job1 number;
  l_job2 number;
  l_key1 varchar2(64);
  l_key2 varchar2(64);
  l_a    number;
  l_kml  clob;
  l_n    number;
  l_status varchar2(20);
begin
  --- two jobs get two different, 64-char keys -------------------------------
  l_job1 := pck_kml_job_api.create_job(p_document_name => 'Public smoke 1', p_output_format => 'KML');
  l_job2 := pck_kml_job_api.create_job(p_document_name => 'Public smoke 2', p_output_format => 'KML');
  l_key1 := pck_kml_job_api.get_access_key(l_job1);
  l_key2 := pck_kml_job_api.get_access_key(l_job2);

  dbms_output.put_line('key1 len   : ' || length(l_key1) || ' (expect 64)');
  dbms_output.put_line('key1 != key2: ' || case when l_key1 <> l_key2 then 'OK' else 'FAIL' end);
  dbms_output.put_line('key is hex : ' || case when regexp_like(l_key1, '^[0-9a-f]{64}$') then 'OK' else 'FAIL' end);

  --- add an asset to job 1 --------------------------------------------------
  l_a := pck_kml_job_api.add_asset(
           p_job_id           => l_job1,
           p_geometry_geojson => to_clob('{"type":"Point","coordinates":[13.405,52.52]}'),
           p_name             => 'Berlin',
           p_line_color       => pck_kml_engine.rgba_to_kml('FF0000'),
           p_extended_data    => to_clob('{"country":"DE"}'));
  commit;

  --- on-the-fly render: build_kml must NOT submit or delete assets ----------
  l_kml := pck_kml_engine.build_kml(l_job1);
  select count(*) into l_n from kml_job_assets where job_id = l_job1;
  l_status := pck_kml_job_api.get_status(l_job1);

  dbms_output.put_line('kml length : ' || nvl(dbms_lob.getlength(l_kml), 0) || ' (expect > 0)');
  dbms_output.put_line('assets kept: ' || l_n || ' (expect 1 - build_kml must not clean up)');
  dbms_output.put_line('job status : ' || l_status || ' (expect DRAFT - never submitted)');

  --- access lookup the auth scheme performs --------------------------------
  select count(*) into l_n from kml_jobs where job_id = l_job1 and access_key = l_key1;
  dbms_output.put_line('auth match : ' || l_n || ' (expect 1)');
  select count(*) into l_n from kml_jobs where job_id = l_job1 and access_key = 'wrong';
  dbms_output.put_line('bad key    : ' || l_n || ' (expect 0)');

  --- clean up the smoke jobs ------------------------------------------------
  pck_kml_jobs_dml.del(l_job1);
  pck_kml_jobs_dml.del(l_job2);
  commit;

  dbms_output.put_line('--------------------------------------------------');
  dbms_output.put_line('public smoke test done');
end;
/
