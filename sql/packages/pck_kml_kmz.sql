--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_KMZ  (KMZ packaging)
--------------------------------------------------------------------------------
-- A KMZ is a ZIP archive containing the KML as "doc.kml" at its root.
--
-- The body depends on APEX_ZIP (ships with Oracle APEX). The dependency is
-- isolated here: the spec has no APEX reference, so PCK_KML_ENGINE always
-- compiles; only this body becomes invalid without APEX, and KMZ jobs then fail
-- at runtime while KML output keeps working. No APEX? Swap the body for a
-- pure-PL/SQL zipper such as AS_ZIP -- the spec stays unchanged.
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
    l_zip blob;
  begin
    apex_zip.add_file(
      p_zipped_blob => l_zip,
      p_file_name   => p_entry_name,
      p_content     => clob_to_blob(p_kml)
    );
    apex_zip.finish(p_zipped_blob => l_zip);
    return l_zip;
  end zip_kml;

end pck_kml_kmz;
/
