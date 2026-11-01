--------------------------------------------------------------------------------
-- KMLeon :: protect the REST API (ORDS privilege + OAuth2 client credentials)
--------------------------------------------------------------------------------
-- Run AFTER 010_rest_api.sql, as the schema that owns the KMLeon objects
-- (APEX > SQL Workshop > SQL Scripts, or SQLcl). Re-runnable.
--
-- What it does
--   1. role       "KMLeon User"
--   2. privilege  kmleon.access  on /kmleon/v1/*  -> every endpoint needs the role
--   3. OAuth2 client "kmleon_client" (grant type client_credentials) holding
--      the role; its client_id / client_secret are printed at the end.
--
-- How a client calls the API afterwards
--   TOKEN=$(curl -s -u "<client_id>:<client_secret>" \
--             --data "grant_type=client_credentials" \
--             https://host/ords/<schema-alias>/oauth/token | jq -r .access_token)
--   curl -H "Authorization: Bearer $TOKEN" https://host/ords/<schema-alias>/kmleon/v1/jobs
--   Tokens expire (default 3600 s); request a new one when you get 401.
--
-- Rotate the secret:  exec oauth.update_client_secret('kmleon_client'); commit;
-- Undo everything:    see the bottom of this file.
-- Use HTTPS in front of ORDS -- the token travels in a header.
--------------------------------------------------------------------------------

set define off
set serveroutput on

declare
  l_roles    owa.vc_arr;
  l_patterns owa.vc_arr;
begin
  -- 1. role (ignore "already exists")
  begin
    ords.create_role(p_role_name => 'KMLeon User');
  exception when others then null;
  end;

  -- 2. privilege (define_privilege is an upsert); owa.vc_arr is the array type
  --    the ORDS PL/SQL API takes (the old ORDS_T_STRINGS type is not public any more)
  l_roles(1)    := 'KMLeon User';
  l_patterns(1) := '/kmleon/v1/*';
  ords.define_privilege(
    p_privilege_name => 'kmleon.access',
    p_roles          => l_roles,
    p_patterns       => l_patterns,
    p_label          => 'KMLeon API',
    p_description    => 'Access to the KMLeon REST API (kmleon.v1)');

  -- 3. OAuth2 client with the role (recreate so the script is re-runnable)
  begin
    oauth.delete_client(p_name => 'kmleon_client');
  exception when others then null;
  end;
  oauth.create_client(
    p_name            => 'kmleon_client',
    p_grant_type      => 'client_credentials',
    p_owner           => 'KMLeon',
    p_description     => 'Machine client for the KMLeon REST API',
    p_support_email   => 'kmleon@example.com',
    p_privilege_names => 'kmleon.access');
  oauth.grant_client_role(p_client_name => 'kmleon_client', p_role_name => 'KMLeon User');
  commit;
  dbms_output.put_line('kmleon.v1 is now protected; client "kmleon_client" created.');
end;
/

prompt -- credentials for the client_credentials flow (keep them secret):
column name          format a16
column client_id     format a40
column client_secret format a40
select name, client_id, client_secret
  from user_ords_clients
 where name = 'kmleon_client';

--------------------------------------------------------------------------------
-- Undo (make the module public again):
--   begin
--     oauth.delete_client(p_name => 'kmleon_client');
--     ords.delete_privilege(p_name => 'kmleon.access');
--     ords.delete_role(p_role_name => 'KMLeon User');
--     commit;
--   end;
--   /
--------------------------------------------------------------------------------
