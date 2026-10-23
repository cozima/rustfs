#!/usr/bin/env bash
# Checks bucket-level CORS on a running RustFS at $1 (host:port) with RUSTFS_SERVER_DOMAINS=localhost.
# Exits non-zero if any expectation fails. Prints every response for the log.
set -u
EP="$1"; PORT="${EP##*:}"; BUCKET="corsbucket"
export AWS_ACCESS_KEY_ID=minio AWS_SECRET_ACCESS_KEY=minio123 AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url "http://$EP" s3api create-bucket --bucket "$BUCKET" >/dev/null
aws --endpoint-url "http://$EP" s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{"CORSRules":[{"AllowedOrigins":["http://localhost:5173"],"AllowedMethods":["GET","PUT","HEAD"],"AllowedHeaders":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3000}]}'
echo hello > /tmp/obj.txt
aws --endpoint-url "http://$EP" s3api put-object --bucket "$BUCKET" --key obj.txt --body /tmp/obj.txt >/dev/null

fail=0
# expect <name> <expected status> <expected ACAO or "-"> <curl args...>
expect() {
  local name="$1" want_status="$2" want_acao="$3"; shift 3
  local out status acao
  out=$(curl -s -o /dev/null -D - --resolve "$BUCKET.localhost:$PORT:127.0.0.1" "$@")
  status=$(printf '%s' "$out" | head -1 | awk '{print $2}')
  acao=$(printf '%s' "$out" | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')
  [ -z "$acao" ] && acao="-"
  if [ "$status" = "$want_status" ] && [ "$acao" = "$want_acao" ]; then r=PASS; else r=FAIL; fail=1; fi
  echo "$r  $name: status=$status ACAO=$acao (want $want_status / $want_acao)"
}
PRE=(-X OPTIONS -H 'Access-Control-Request-Method: PUT' -H 'Access-Control-Request-Headers: content-type')
expect "path-style preflight, allowed origin"     200 http://localhost:5173 "${PRE[@]}" -H 'Origin: http://localhost:5173' "http://localhost:$PORT/$BUCKET/obj.txt"
expect "path-style preflight, other origin"       403 -                     "${PRE[@]}" -H 'Origin: http://evil.example' "http://localhost:$PORT/$BUCKET/obj.txt"
expect "virtual-host preflight, allowed origin"   200 http://localhost:5173 "${PRE[@]}" -H 'Origin: http://localhost:5173' "http://$BUCKET.localhost:$PORT/obj.txt"
expect "virtual-host preflight, other origin"     403 -                     "${PRE[@]}" -H 'Origin: http://evil.example' "http://$BUCKET.localhost:$PORT/obj.txt"
expect "virtual-host bucket-root preflight"       200 http://localhost:5173 "${PRE[@]}" -H 'Origin: http://localhost:5173' "http://$BUCKET.localhost:$PORT/"
GET_URL=$(aws configure set default.s3.addressing_style virtual && aws --endpoint-url "http://localhost:$PORT" s3 presign "s3://$BUCKET/obj.txt" --expires-in 300)
echo "presigned virtual-host GET: $GET_URL"
expect "virtual-host presigned GET, allowed origin" 200 http://localhost:5173 -H 'Origin: http://localhost:5173' "$GET_URL"
aws configure set default.s3.addressing_style path
exit $fail
