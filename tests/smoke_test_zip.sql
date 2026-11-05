--------------------------------------------------------------------------------
-- KMLeon :: smoke test - PCK_KML_ZIP (pure PL/SQL ZIP writer / reader)
--------------------------------------------------------------------------------
-- Writes an archive with a text entry, a 200 KB pseudo-random binary entry and
-- an empty entry, then reads it back: signatures, entry list, round-trip of
-- every entry (DEFLATE via UTL_COMPRESS, CRC from the gzip trailer), and the
-- KMZ path through PCK_KML_KMZ.zip_kml. Needs neither APEX nor the Oracle JVM.
--------------------------------------------------------------------------------
set serveroutput on size unlimited

declare
  l_zip   blob;
  l_txt   blob := utl_raw.cast_to_raw('<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>zip test äöü €</name></Document></kml>');
  l_bin   blob;
  l_empty blob;
  l_back  blob;
  l_names pck_kml_zip.t_names;
  l_len   integer;
  l_n     pls_integer := 0;
  procedure must(p_cond in boolean, p_what in varchar2) is
  begin
    l_n := l_n + 1;
    if not p_cond then
      raise_application_error(-20999, 'zip smoke FAILED: ' || p_what);
    end if;
    dbms_output.put_line('OK   ' || p_what);
  end must;
begin
  -- 200 KB of pseudo-random bytes (compresses badly: exercises the sizes/offsets)
  dbms_lob.createtemporary(l_bin, true);
  for i in 1 .. 200 loop
    dbms_lob.writeappend(l_bin, 1024, dbms_crypto.randombytes(1024));
  end loop;
  dbms_lob.createtemporary(l_empty, true);

  pck_kml_zip.add_file(l_zip, 'doc.kml', l_txt, to_date('2026-11-01 12:34:56', 'YYYY-MM-DD HH24:MI:SS'));
  pck_kml_zip.add_file(l_zip, 'files/blob.bin', l_bin);
  pck_kml_zip.add_file(l_zip, 'empty.txt', l_empty);
  pck_kml_zip.finish(l_zip);
  l_len := dbms_lob.getlength(l_zip);

  must(rawtohex(dbms_lob.substr(l_zip, 4, 1)) = '504B0304', 'local file header signature');
  must(rawtohex(dbms_lob.substr(l_zip, 4, l_len - 21)) = '504B0506', 'end of central directory record');
  must(dbms_lob.instr(l_zip, hextoraw('504B0102')) > 0, 'central directory present');
  must(rawtohex(dbms_lob.substr(l_zip, 2, 7)) = '0008', 'UTF-8 name flag (bit 11) set');

  l_names := pck_kml_zip.file_list(l_zip);
  must(l_names.count = 3 and l_names(1) = 'doc.kml' and l_names(2) = 'files/blob.bin' and l_names(3) = 'empty.txt', 'file_list: 3 entries in order');

  l_back := pck_kml_zip.get_file(l_zip, 'doc.kml');
  must(dbms_lob.compare(l_back, l_txt) = 0, 'text entry round-trips (UTF-8 content)');
  l_back := pck_kml_zip.get_file(l_zip, 'files/blob.bin');
  must(dbms_lob.compare(l_back, l_bin) = 0, '200 KB binary entry round-trips');
  l_back := pck_kml_zip.get_file(l_zip, 'empty.txt');
  must(dbms_lob.getlength(l_back) = 0, 'empty entry round-trips');
  must(pck_kml_zip.get_file(l_zip, 'nope') is null, 'unknown entry -> null');
  must(l_len < dbms_lob.getlength(l_bin) + dbms_lob.getlength(l_txt) + 400, 'archive overhead is small');

  -- KMZ path
  dbms_lob.freetemporary(l_zip);
  l_zip := pck_kml_kmz.zip_kml(to_clob('<kml><Document><name>kmz</name></Document></kml>'));
  l_names := pck_kml_zip.file_list(l_zip);
  must(l_names.count = 1 and l_names(1) = 'doc.kml', 'zip_kml: single doc.kml entry');
  must(utl_raw.cast_to_varchar2(dbms_lob.substr(pck_kml_zip.get_file(l_zip, 'doc.kml'), 50, 1)) like '<kml><Document><name>kmz</name>%', 'zip_kml: content readable');

  dbms_output.put_line('zip smoke test OK (' || l_n || ' checks)');
  -- run_all.sql summary: mark this script as passed (no-op when run standalone)
  begin execute immediate q'[insert into kml_test_results (test) values ('smoke_test_zip')]'; exception when others then null; end;
end;
/
