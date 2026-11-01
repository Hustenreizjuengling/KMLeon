--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_KMZ  (KMZ packaging)
--------------------------------------------------------------------------------
-- A KMZ is a ZIP archive containing the KML as "doc.kml" at its root.
--
-- The archive is written by PCK_KML_ZIP -- pure PL/SQL on top of UTL_COMPRESS,
-- so KMZ output needs neither APEX nor the Oracle JVM (KMZ_ENGINE = INTERNAL,
-- the default). Installations that prefer APEX_ZIP can set KMZ_ENGINE = APEX;
-- it is then called dynamically, so this package compiles without APEX.
--------------------------------------------------------------------------------

create or replace package pck_kml_kmz
  authid definer
as
  function zip_kml(p_kml in clob, p_entry_name in varchar2 default 'doc.kml') return blob;
end pck_kml_kmz;
/

create or replace package body pck_kml_kmz
as

  function clob_to_blob(p_clob in clob) return blob
  is
    l_blob         blob;
    l_dest_offset  integer := 1;
    l_src_offset   integer := 1;
    l_lang_context integer := dbms_lob.default_lang_ctx;
    l_warning      integer;
  begin
    if p_clob is null then
      return null;
    end if;
    dbms_lob.createtemporary(l_blob, true);
    dbms_lob.converttoblob(
      dest_lob     => l_blob,
      src_clob     => p_clob,
      amount       => dbms_lob.lobmaxsize,
      dest_offset  => l_dest_offset,
      src_offset   => l_src_offset,
      blob_csid    => nls_charset_id('AL32UTF8'),
      lang_context => l_lang_context,
      warning      => l_warning
    );
    return l_blob;
  exception
    when others then   -- never leak the temporary LOB if conversion fails
      if dbms_lob.istemporary(l_blob) = 1 then
        dbms_lob.freetemporary(l_blob);
      end if;
      raise;
  end clob_to_blob;


  function zip_kml(p_kml in clob, p_entry_name in varchar2 default 'doc.kml') return blob
  is
    l_zip     blob;
    l_content blob;
    l_engine  varchar2(20) := upper(nvl(pck_kml_config_dml.get_string('KMZ_ENGINE'), 'INTERNAL'));
  begin
    l_content := clob_to_blob(p_kml);   -- hold the temp LOB so we can free it
    if l_engine = 'APEX' then
      -- optional: APEX_ZIP, bound at run time only (no compile-time dependency)
      execute immediate q'[
        begin
          apex_zip.add_file(p_zipped_blob => :z, p_file_name => :n, p_content => :c);
          apex_zip.finish(p_zipped_blob => :z);
        end;]'
        using in out l_zip, in p_entry_name, in l_content;
    else
      pck_kml_zip.add_file(l_zip, p_entry_name, l_content);
      pck_kml_zip.finish(l_zip);
    end if;
    if dbms_lob.istemporary(l_content) = 1 then
      dbms_lob.freetemporary(l_content);
    end if;
    return l_zip;
  exception
    when others then
      if dbms_lob.istemporary(l_content) = 1 then
        dbms_lob.freetemporary(l_content);
      end if;
      raise;
  end zip_kml;

end pck_kml_kmz;
/
