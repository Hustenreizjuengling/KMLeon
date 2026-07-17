--------------------------------------------------------------------------------
-- KMLeon :: smoke test - error contract
--------------------------------------------------------------------------------
-- Asserts the documented error codes (they are the API contract, e.g. for the
-- ORDS handlers' HTTP status mapping):
--   -20812 QUERY job without source_query        -20813 job not found
--   -20820 asset without geometry                -20821 invalid GeoJSON
--   -20810 submit of a non-DRAFT job             -20811 cancel of a terminal job
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job number;
  l_n   number;
  l_s   varchar2(20);
begin
  --- -20812: QUERY job requires a source_query ---------------------------------
  begin
    l_job := pck_kml_job_api.create_job_from_query('errors smoke', null);
    raise_application_error(-20999, 'errors smoke FAILED: -20812 not raised');
  exception when others then
    if sqlcode != -20812 then raise; end if;
  end;
  dbms_output.put_line('-20812 OK   (QUERY without source_query)');

  l_job := pck_kml_job_api.create_job(p_document_name => 'Errors smoke', p_output_format => 'KML');

  --- -20820: asset needs a geometry --------------------------------------------
  begin
    l_n := pck_kml_job_api.add_asset(p_job_id => l_job);
    raise_application_error(-20999, 'errors smoke FAILED: -20820 not raised');
  exception when others then
    if sqlcode != -20820 then raise; end if;
  end;
  dbms_output.put_line('-20820 OK   (asset without geometry)');

  --- -20821: invalid GeoJSON payload -------------------------------------------
  begin
    l_n := pck_kml_job_api.add_features_geojson(l_job, to_clob('{not valid json'));
    raise_application_error(-20999, 'errors smoke FAILED: -20821 not raised');
  exception when others then
    if sqlcode != -20821 then raise; end if;
  end;
  dbms_output.put_line('-20821 OK   (invalid GeoJSON)');

  --- -20813: job not found -----------------------------------------------------
  begin
    l_s := pck_kml_job_api.get_status(-1);
    raise_application_error(-20999, 'errors smoke FAILED: -20813 not raised');
  exception when others then
    if sqlcode != -20813 then raise; end if;
  end;
  dbms_output.put_line('-20813 OK   (job not found)');

  --- -20810: submit requires DRAFT ---------------------------------------------
  pck_kml_jobs_dml.set_status(l_job, 'PENDING');
  begin
    pck_kml_job_api.submit_job(l_job);
    raise_application_error(-20999, 'errors smoke FAILED: -20810 not raised');
  exception when others then
    if sqlcode != -20810 then raise; end if;
  end;
  dbms_output.put_line('-20810 OK   (submit of non-DRAFT)');

  --- -20811: cancel only DRAFT/PENDING... make it terminal first ---------------
  pck_kml_jobs_dml.set_status(l_job, 'COMPLETED');
  begin
    pck_kml_job_api.cancel_job(l_job);
    raise_application_error(-20999, 'errors smoke FAILED: -20811 not raised');
  exception when others then
    if sqlcode != -20811 then raise; end if;
  end;
  dbms_output.put_line('-20811 OK   (cancel of terminal job)');

  pck_kml_jobs_dml.del(l_job);   -- cleanup
  commit;
  dbms_output.put_line('error-contract smoke test OK (job cleaned up)');
end;
/
