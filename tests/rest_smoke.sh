#!/usr/bin/env bash
# KMLeon :: REST smoke test (curl + jq) against a deployed kmleon.v1 module.
#   tests/rest_smoke.sh http://host:8080/ords/<schema-alias>/kmleon/v1 [client_id client_secret]
# With client credentials (020_rest_protect.sql) a bearer token is fetched first and the
# unauthenticated call is expected to be refused. Exit code 0 = all checks passed.
set -u
B=${1:?base url, e.g. http://localhost:8080/ords/kml/kmleon/v1}
CID=${2:-}; CSEC=${3:-}
AUTH=()
fail=0; n=0
ok()  { n=$((n+1)); echo "OK   $1"; }
bad() { n=$((n+1)); fail=$((fail+1)); echo "FAIL $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1 -> $2"; else bad "$1 -> got '$2', expected '$3'"; fi; }
code(){ curl -s -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$@"; }

if [ -n "$CID" ]; then
  check "unauthenticated GET jobs refused" "$(curl -s -o /dev/null -w '%{http_code}' "$B/jobs")" 401
  TOKEN_URL="${B%/kmleon/v1}/oauth/token"
  TOKEN=$(curl -s -u "$CID:$CSEC" --data "grant_type=client_credentials" "$TOKEN_URL" | jq -r .access_token)
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && ok "token obtained" || bad "no token from $TOKEN_URL"
  AUTH=(-H "Authorization: Bearer $TOKEN")
fi

V=$(curl -s "${AUTH[@]}" "$B/version")
[ "$(echo "$V" | jq -r .api)" = "v1" ] && ok "GET version -> $(echo "$V" | jq -c .)" || bad "GET version -> $V"

R=$(curl -s "${AUTH[@]}" -X POST -H 'Content-Type: application/json' \
      -d '{"document_name":"REST smoke \"quoted\" / slash","output_format":"KMZ","notify_email":"rest@example.com"}' "$B/jobs")
ID=$(echo "$R" | jq -r .job_id); KEY=$(echo "$R" | jq -r .access_key)
[[ "$ID" =~ ^[0-9]+$ ]] && [ ${#KEY} = 64 ] && ok "POST jobs -> job $ID, 64-char key, editor_url=$(echo "$R" | jq -r '.editor_url != null')" || bad "POST jobs -> $R"
check "POST jobs without document_name" "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$B/jobs")" 400

FC='{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[13.405,52.52]},"properties":{"NAME":"Berlin","FOLDER_NAME":"Cities","country":"DE"}},{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[13.3,52.4],[13.5,52.4],[13.5,52.6],[13.3,52.6],[13.3,52.4]]]},"properties":{"NAME":"Area","POLY_COLOR":"7f0000ff"}}]}'
check "POST features" "$(curl -s "${AUTH[@]}" -X POST -H 'Content-Type: application/json' --data-binary "$FC" "$B/jobs/$ID/features" | jq -r .features_added)" 2
check "POST features bad GeoJSON" "$(code -X POST -H 'Content-Type: application/json' -d '{"type":"Feature"' "$B/jobs/$ID/features")" 400
check "GET editor-link (right key)" "$(curl -s "${AUTH[@]}" "$B/jobs/$ID/editor-link?key=$KEY" | jq -r '.editor_url | contains("public-editor-v2")')" true
check "GET editor-link (wrong key)" "$(code "$B/jobs/$ID/editor-link?key=wrong")" 404
check "DELETE while DRAFT allowed? (no: we run first)" "$(curl -s "${AUTH[@]}" "$B/jobs/$ID" | jq -r .status)" DRAFT
check "POST run" "$(curl -s "${AUTH[@]}" -X POST "$B/jobs/$ID/run" | jq -r .status)" COMPLETED
check "GET job asset_count" "$(curl -s "${AUTH[@]}" "$B/jobs/$ID" | jq -r .asset_count)" 2
check "GET result content-type" "$(curl -s "${AUTH[@]}" -o /dev/null -w '%{content_type}' "$B/jobs/$ID/result")" application/vnd.google-earth.kmz
check "POST cancel completed job" "$(code -X POST "$B/jobs/$ID/cancel")" 409
check "POST submit completed job" "$(code -X POST "$B/jobs/$ID/submit")" 409
check "GET unknown job" "$(code "$B/jobs/999999999")" 404
check "GET non-numeric id" "$(code "$B/jobs/abc")" 400
check "GET result of unknown job" "$(code "$B/jobs/999999999/result")" 404
check "DELETE job" "$(curl -s "${AUTH[@]}" -X DELETE "$B/jobs/$ID" | jq -r .deleted)" true
check "GET deleted job" "$(code "$B/jobs/$ID")" 404
check "DELETE unknown job" "$(code -X DELETE "$B/jobs/$ID")" 404
# a pending job must not be deletable
R=$(curl -s "${AUTH[@]}" -X POST -H 'Content-Type: application/json' -d '{"document_name":"pending"}' "$B/jobs"); ID2=$(echo "$R" | jq -r .job_id)
check "POST submit" "$(curl -s "${AUTH[@]}" -X POST "$B/jobs/$ID2/submit" | jq -r .status)" PENDING
check "DELETE pending job" "$(code -X DELETE "$B/jobs/$ID2")" 409
check "POST cancel pending job" "$(curl -s "${AUTH[@]}" -X POST "$B/jobs/$ID2/cancel" | jq -r .status)" CANCELLED
check "DELETE cancelled job" "$(curl -s "${AUTH[@]}" -X DELETE "$B/jobs/$ID2" | jq -r .deleted)" true
check "GET jobs lists" "$(curl -s "${AUTH[@]}" "$B/jobs" | jq -r '.items | type')" array

echo "----"
if [ $fail = 0 ]; then echo "REST smoke: all $n checks passed"; else echo "REST smoke: $fail of $n checks FAILED"; fi
exit $fail
