--------------------------------------------------------------------------------
-- KMLeon :: PCK_KML_ZIP  (pure PL/SQL ZIP writer / reader -- no APEX, no JVM)
--------------------------------------------------------------------------------
-- Minimal, standards-compliant ZIP (PKWARE APPNOTE 6.3.x) in plain PL/SQL:
--   * entries are DEFLATE-compressed with UTL_COMPRESS (zlib inside the kernel,
--     available in every edition, no Java); the CRC-32 is taken from the gzip
--     trailer UTL_COMPRESS produces, so no byte loop is needed;
--   * file names are stored as UTF-8 (general purpose bit 11);
--   * the central directory is rebuilt from the local headers in finish(), so
--     the API is stateless: add_file() any number of times, then finish().
-- Also reads archives (file_list / get_file) -- used by the tests to verify
-- what was written, and handy for consumers.
--
-- Limits: single archive < 4 GB and < 65535 entries (no ZIP64) -- far beyond
-- any KMZ. KMZ needs exactly one entry, doc.kml (see PCK_KML_KMZ).
--------------------------------------------------------------------------------

create or replace package pck_kml_zip
  authid definer
as
  -- Append one entry. p_zip may be NULL on the first call (a temporary BLOB is
  -- created). p_date defaults to SYSDATE (stored as local DOS time).
  procedure add_file(
    p_zip       in out nocopy blob,
    p_file_name in varchar2,
    p_content   in blob,
    p_date      in date default sysdate
  );

  -- Write the central directory + end record. Call once, after the last add_file.
  procedure finish(p_zip in out nocopy blob);

  -- Entry names of an archive (in central-directory order).
  type t_names is table of varchar2(4000);
  function file_list(p_zip in blob) return t_names;

  -- Content of one entry (methods STORE and DEFLATE). NULL when not found.
  function get_file(p_zip in blob, p_file_name in varchar2) return blob;
end pck_kml_zip;
/

create or replace package body pck_kml_zip
as
  c_local_sig   constant raw(4) := hextoraw('504B0304');
  c_central_sig constant raw(4) := hextoraw('504B0102');
  c_end_sig     constant raw(4) := hextoraw('504B0506');
  c_version     constant raw(2) := hextoraw('1400');       -- 2.0 (deflate)
  c_flags       constant raw(2) := hextoraw('0008');       -- bit 11: UTF-8 names
  c_m_store     constant raw(2) := hextoraw('0000');
  c_m_deflate   constant raw(2) := hextoraw('0800');

  -- n as p_bytes little-endian bytes (n >= 0, < 2^31)
  function le(p_n in number, p_bytes in pls_integer) return raw is
  begin
    return utl_raw.substr(utl_raw.cast_from_binary_integer(p_n, utl_raw.little_endian), 1, p_bytes);
  end le;

  -- little-endian bytes -> number (unsigned)
  function num(p_raw in raw) return number is
    l number := 0;
  begin
    for i in reverse 1 .. utl_raw.length(p_raw) loop
      l := l * 256 + to_number(rawtohex(utl_raw.substr(p_raw, i, 1)), 'XX');
    end loop;
    return l;
  end num;

  function dos_time(p_date in date) return raw is
  begin
    return le(to_number(to_char(p_date, 'HH24')) * 2048
              + to_number(to_char(p_date, 'MI')) * 32
              + trunc(to_number(to_char(p_date, 'SS')) / 2), 2);
  end dos_time;

  function dos_date(p_date in date) return raw is
  begin
    return le((greatest(to_number(to_char(p_date, 'YYYY')), 1980) - 1980) * 512
              + to_number(to_char(p_date, 'MM')) * 32
              + to_number(to_char(p_date, 'DD')), 2);
  end dos_date;


  procedure add_file(
    p_zip       in out nocopy blob,
    p_file_name in varchar2,
    p_content   in blob,
    p_date      in date default sysdate
  ) is
    l_name   raw(32767) := utl_raw.cast_to_raw(p_file_name);
    l_gz     blob;
    l_len    integer := nvl(dbms_lob.getlength(p_content), 0);
    l_gzlen  integer;
    l_crc    raw(4) := hextoraw('00000000');
    l_method raw(2) := c_m_store;
    l_csize  integer := 0;
    l_hdr    raw(200);
  begin
    if p_file_name is null then
      raise_application_error(-20850, 'pck_kml_zip.add_file: file name is required');
    end if;
    if p_zip is null then
      dbms_lob.createtemporary(p_zip, true);
    end if;

    if l_len > 0 then
      -- gzip = 10-byte header | raw deflate | CRC-32 (LE) | ISIZE (LE)
      l_gz    := utl_compress.lz_compress(p_content, 9);
      l_gzlen := dbms_lob.getlength(l_gz);
      l_crc   := dbms_lob.substr(l_gz, 4, l_gzlen - 7);
      l_csize := l_gzlen - 18;
      l_method := c_m_deflate;
    end if;

    l_hdr := utl_raw.concat(
               c_local_sig, c_version, c_flags, l_method,
               dos_time(p_date), dos_date(p_date),
               l_crc, le(l_csize, 4), le(l_len, 4),
               le(utl_raw.length(l_name), 2), le(0, 2));
    dbms_lob.writeappend(p_zip, utl_raw.length(l_hdr), l_hdr);
    dbms_lob.writeappend(p_zip, utl_raw.length(l_name), l_name);
    if l_len > 0 then
      dbms_lob.copy(p_zip, l_gz, l_csize, dbms_lob.getlength(p_zip) + 1, 11);
      dbms_lob.freetemporary(l_gz);
    end if;
  exception
    when others then
      if l_gz is not null and dbms_lob.istemporary(l_gz) = 1 then
        dbms_lob.freetemporary(l_gz);
      end if;
      raise;
  end add_file;


  procedure finish(p_zip in out nocopy blob) is
    l_pos     integer := 1;                 -- 1-based offset of the next local header
    l_len     integer := nvl(dbms_lob.getlength(p_zip), 0);
    l_hdr     raw(30);
    l_name    raw(32767);
    l_nlen    pls_integer;
    l_xlen    pls_integer;
    l_csize   integer;
    l_cd      blob;                         -- central directory (built separately, appended at the end)
    l_entries pls_integer := 0;
    l_rec     raw(200);
    l_cd_off  integer;
    l_cd_len  integer;
  begin
    if p_zip is null then
      dbms_lob.createtemporary(p_zip, true);
    end if;
    dbms_lob.createtemporary(l_cd, true);

    while l_pos + 29 <= l_len loop
      l_hdr := dbms_lob.substr(p_zip, 30, l_pos);
      exit when utl_raw.substr(l_hdr, 1, 4) <> c_local_sig;   -- end of local entries
      l_csize := num(utl_raw.substr(l_hdr, 19, 4));
      l_nlen  := num(utl_raw.substr(l_hdr, 27, 2));
      l_xlen  := num(utl_raw.substr(l_hdr, 29, 2));
      l_name  := dbms_lob.substr(p_zip, l_nlen, l_pos + 30);
      -- central header: sig, version made by, version needed, flags, method, time,
      -- date, crc, csize, usize, nlen, xlen=0, clen=0, disk=0, int attr=0,
      -- ext attr=0, local header offset (0-based), name
      l_rec := utl_raw.concat(
                 c_central_sig, c_version,
                 utl_raw.substr(l_hdr, 5, 22),              -- version..usize copied from the local header
                 le(l_nlen, 2), le(0, 2), le(0, 2), le(0, 2), le(0, 2), le(0, 4),
                 le(l_pos - 1, 4));
      dbms_lob.writeappend(l_cd, utl_raw.length(l_rec), l_rec);
      dbms_lob.writeappend(l_cd, l_nlen, l_name);
      l_entries := l_entries + 1;
      l_pos := l_pos + 30 + l_nlen + l_xlen + l_csize;
    end loop;

    l_cd_off := l_pos - 1;                  -- central directory starts right after the entries
    l_cd_len := dbms_lob.getlength(l_cd);
    if l_cd_len > 0 then
      dbms_lob.copy(p_zip, l_cd, l_cd_len, l_cd_off + 1, 1);
    end if;
    l_rec := utl_raw.concat(c_end_sig, le(0, 2), le(0, 2), le(l_entries, 2), le(l_entries, 2),
                            le(l_cd_len, 4), le(l_cd_off, 4), le(0, 2));
    dbms_lob.writeappend(p_zip, utl_raw.length(l_rec), l_rec);
    dbms_lob.freetemporary(l_cd);
  exception
    when others then
      if l_cd is not null and dbms_lob.istemporary(l_cd) = 1 then
        dbms_lob.freetemporary(l_cd);
      end if;
      raise;
  end finish;


  -- locate the end record (no archive comment supported) and return cd offset / entries
  procedure read_end(p_zip in blob, p_cd_off out integer, p_entries out pls_integer) is
    l_len integer := nvl(dbms_lob.getlength(p_zip), 0);
    l_end raw(22);
  begin
    if l_len < 22 then
      raise_application_error(-20851, 'pck_kml_zip: not a ZIP archive (too short)');
    end if;
    l_end := dbms_lob.substr(p_zip, 22, l_len - 21);
    if utl_raw.substr(l_end, 1, 4) <> c_end_sig then
      raise_application_error(-20851, 'pck_kml_zip: end of central directory not found (archive comment?)');
    end if;
    p_entries := num(utl_raw.substr(l_end, 11, 2));
    p_cd_off  := num(utl_raw.substr(l_end, 17, 4));
  end read_end;


  function file_list(p_zip in blob) return t_names is
    l_names   t_names := t_names();
    l_cd_off  integer;
    l_entries pls_integer;
    l_pos     integer;
    l_hdr     raw(46);
    l_nlen    pls_integer;
    l_xlen    pls_integer;
    l_clen    pls_integer;
  begin
    read_end(p_zip, l_cd_off, l_entries);
    l_pos := l_cd_off + 1;
    for i in 1 .. l_entries loop
      l_hdr := dbms_lob.substr(p_zip, 46, l_pos);
      exit when utl_raw.substr(l_hdr, 1, 4) <> c_central_sig;
      l_nlen := num(utl_raw.substr(l_hdr, 29, 2));
      l_xlen := num(utl_raw.substr(l_hdr, 31, 2));
      l_clen := num(utl_raw.substr(l_hdr, 33, 2));
      l_names.extend;
      l_names(l_names.count) := utl_raw.cast_to_varchar2(dbms_lob.substr(p_zip, l_nlen, l_pos + 46));
      l_pos := l_pos + 46 + l_nlen + l_xlen + l_clen;
    end loop;
    return l_names;
  end file_list;


  function get_file(p_zip in blob, p_file_name in varchar2) return blob is
    l_cd_off  integer;
    l_entries pls_integer;
    l_pos     integer;
    l_hdr     raw(46);
    l_nlen    pls_integer;
    l_xlen    pls_integer;
    l_clen    pls_integer;
    l_name    varchar2(4000);
    l_method  pls_integer;
    l_crc     raw(4);
    l_csize   integer;
    l_usize   integer;
    l_loc     integer;
    l_lhdr    raw(30);
    l_data    integer;
    l_out     blob;
    l_gz      blob;
  begin
    read_end(p_zip, l_cd_off, l_entries);
    l_pos := l_cd_off + 1;
    for i in 1 .. l_entries loop
      l_hdr := dbms_lob.substr(p_zip, 46, l_pos);
      exit when utl_raw.substr(l_hdr, 1, 4) <> c_central_sig;
      l_nlen := num(utl_raw.substr(l_hdr, 29, 2));
      l_xlen := num(utl_raw.substr(l_hdr, 31, 2));
      l_clen := num(utl_raw.substr(l_hdr, 33, 2));
      l_name := utl_raw.cast_to_varchar2(dbms_lob.substr(p_zip, l_nlen, l_pos + 46));
      if l_name = p_file_name then
        l_method := num(utl_raw.substr(l_hdr, 11, 2));
        l_crc    := utl_raw.substr(l_hdr, 17, 4);
        l_csize  := num(utl_raw.substr(l_hdr, 21, 4));
        l_usize  := num(utl_raw.substr(l_hdr, 25, 4));
        l_loc    := num(utl_raw.substr(l_hdr, 43, 4));
        l_lhdr   := dbms_lob.substr(p_zip, 30, l_loc + 1);
        l_data   := l_loc + 1 + 30 + num(utl_raw.substr(l_lhdr, 27, 2)) + num(utl_raw.substr(l_lhdr, 29, 2));
        dbms_lob.createtemporary(l_out, true);
        if l_usize = 0 then
          return l_out;
        elsif l_method = 0 then
          dbms_lob.copy(l_out, p_zip, l_csize, 1, l_data);
          return l_out;
        elsif l_method = 8 then
          -- re-wrap the raw deflate stream as gzip so UTL_COMPRESS can inflate it
          dbms_lob.createtemporary(l_gz, true);
          dbms_lob.writeappend(l_gz, 10, hextoraw('1F8B0800000000000003'));
          dbms_lob.copy(l_gz, p_zip, l_csize, 11, l_data);
          dbms_lob.writeappend(l_gz, 8, utl_raw.concat(l_crc, le(l_usize, 4)));
          l_out := utl_compress.lz_uncompress(l_gz);
          dbms_lob.freetemporary(l_gz);
          return l_out;
        else
          raise_application_error(-20852, 'pck_kml_zip.get_file: unsupported compression method ' || l_method);
        end if;
      end if;
      l_pos := l_pos + 46 + l_nlen + l_xlen + l_clen;
    end loop;
    return null;
  exception
    when others then
      if l_gz is not null and dbms_lob.istemporary(l_gz) = 1 then
        dbms_lob.freetemporary(l_gz);
      end if;
      raise;
  end get_file;

end pck_kml_zip;
/
