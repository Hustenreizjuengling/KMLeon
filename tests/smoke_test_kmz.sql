--------------------------------------------------------------------------------
-- KMLeon :: smoke test - KMZ output (requires APEX_ZIP)
--------------------------------------------------------------------------------
-- Builds a one-point KMZ job and asserts: COMPLETED, non-empty result_kmz, and
-- a real ZIP archive (magic bytes "PK"). Fails with a hint when APEX_ZIP is
-- missing (PCK_KML_KMZ body invalid -> the job FAILs at runtime by design).
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_job number;
  l_a   number;
  l_kmz blob;
  l_doc blob;
begin
  l_job := pck_kml_job_api.create_job(
             p_document_name => 'KMZ smoke test',
             p_output_format => 'KMZ');
  l_a := pck_kml_job_api.add_asset(
           p_job_id           => l_job,
           p_geometry_geojson => to_clob('{"type":"Point","coordinates":[13.405,52.52]}'),
           p_name             => 'Berlin');
  commit;

  pck_kml_job_api.run_now(l_job);

  if pck_kml_job_api.get_status(l_job) != 'COMPLETED' then
    raise_application_error(-20999, 'kmz smoke FAILED: status '
      || pck_kml_job_api.get_status(l_job) || ' (APEX_ZIP missing/invalid?)');
  end if;

  l_kmz := pck_kml_job_api.get_kmz(l_job);
  if nvl(dbms_lob.getlength(l_kmz), 0) = 0 then
    raise_application_error(-20999, 'kmz smoke FAILED: empty result_kmz');
  end if;
  if rawtohex(dbms_lob.substr(l_kmz, 2, 1)) != '504B' then   -- ZIP magic "PK"
    raise_application_error(-20999, 'kmz smoke FAILED: result is not a ZIP archive');
  end if;
  dbms_output.put_line('kmz size    : ' || dbms_lob.getlength(l_kmz) || ' bytes (ZIP magic OK)');
  l_doc := pck_kml_zip.get_file(l_kmz, 'doc.kml');
  if l_doc is null or dbms_lob.instr(l_doc, utl_raw.cast_to_raw('<name>Berlin</name>')) = 0 then
    raise_application_error(-20999, 'kmz smoke FAILED: doc.kml missing or does not contain the placemark');
  end if;
  dbms_output.put_line('doc.kml     : ' || dbms_lob.getlength(l_doc) || ' bytes, placemark present (pure PL/SQL zip)');

  pck_kml_jobs_dml.del(l_job);   -- cleanup
  commit;
  dbms_output.put_line('kmz smoke test OK (job cleaned up)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_kmz')]'; exception when others then null; end;
end;
/
