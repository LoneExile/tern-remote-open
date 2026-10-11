#!/usr/bin/env bash
# Tests for serve.pl against the real script: refusals, headers, integrity,
# idle exit. Needs perl and curl. Prints `FAIL name` lines and exits non-zero on
# any failure (the neuter harness relies on that shape).
set -u
cd "$(dirname "$0")/.."
SERVE="${SERVE:-./serve.pl}"
PERL="${PERL:-perl}"

tmp="$(mktemp -d)"
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); }
bad() { failed=$((failed + 1)); echo "FAIL serve :: $1${2:+ ($2)}"; }
expect() { # name expected actual
  if [ "$2" = "$3" ]; then ok; else bad "$1" "expected '$2', got '$3'"; fi
}

free_port() {
  local p
  for _ in $(seq 1 50); do
    p=$((40000 + RANDOM % 20000))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return; fi
  done
  echo 41234
}

TOKEN=0123456789abcdef0123456789abcdef
printf '<!doctype html><title>t</title><p>hello</p>\n' > "$tmp/page.html"
head -c 300000 /dev/urandom > "$tmp/blob.png"

start() { # file name type idle [downloads copier...] -> sets PORT, PID
  PORT="$(free_port)"
  "$PERL" "$SERVE" "$PORT" "$TOKEN" "$@" >/dev/null 2>&1 &
  PID=$!
  pids+=("$PID")
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return
    sleep 0.1
  done
}
get() { curl -s --max-time 8 -o "$tmp/out" -w '%{http_code}' "$@"; }

# --- argument and startup refusals -----------------------------------------
"$PERL" "$SERVE" >/dev/null 2>&1; expect "no arguments: exit 64" 64 $?
"$PERL" "$SERVE" 99999 "$TOKEN" "$tmp/page.html" page.html text/html 5 >/dev/null 2>&1; expect "port 99999: exit 64" 64 $?
"$PERL" "$SERVE" 40001 short "$tmp/page.html" page.html text/html 5 >/dev/null 2>&1; expect "short token: exit 64" 64 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/page.html" '../x' text/html 5 >/dev/null 2>&1; expect "bad name: exit 64" 64 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/page.html" page.html 'text/html; x' 5 >/dev/null 2>&1; expect "bad type: exit 64" 64 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/nope.html" page.html text/html 5 >/dev/null 2>&1; expect "missing file: exit 65" 65 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp" page.html text/html 5 >/dev/null 2>&1; expect "directory: exit 65" 65 $?

# --- the page ---------------------------------------------------------------
start "$tmp/page.html" page.html "text/html; charset=utf-8" 60
base="http://127.0.0.1:$PORT/$TOKEN/page.html"
if command -v lsof >/dev/null 2>&1; then
  binds="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}' | sort -u | tr '\n' ' ')"
  expect "listens on 127.0.0.1 only" "127.0.0.1:$PORT " "$binds"
fi

expect "GET: 200" 200 "$(get "$base")"
cmp -s "$tmp/out" "$tmp/page.html" && ok || bad "GET: body is the file"
hdr="$(curl -s --max-time 8 -D - -o /dev/null "$base" | tr -d '\r')"
case "$hdr" in *"Content-Type: text/html; charset=utf-8"*) ok ;; *) bad "GET: content type" ;; esac
case "$hdr" in *"Content-Length: $(wc -c < "$tmp/page.html" | tr -d ' ')"*) ok ;; *) bad "GET: content length" ;; esac
case "$hdr" in *"X-Content-Type-Options: nosniff"*) ok ;; *) bad "GET: nosniff" ;; esac
case "$hdr" in *"Cache-Control: no-store"*) ok ;; *) bad "GET: no-store" ;; esac
expect "GET with a query string: 200" 200 "$(get "$base?x=1")"
expect "localhost Host header: 200" 200 "$(get -H "Host: localhost:$PORT" "$base")"

head_out="$(curl -s --max-time 8 -I "$base" | tr -d '\r')"
case "$head_out" in "HTTP/1.1 200"*) ok ;; *) bad "HEAD: 200" ;; esac
# A raw HEAD request: curl would hide a body the server wrongly sent.
exec 5<>"/dev/tcp/127.0.0.1/$PORT"
printf 'HEAD /%s/page.html HTTP/1.1\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\n\r\n' "$TOKEN" "$PORT" >&5
raw="$(cat <&5)"
exec 5>&-
case "$raw" in *hello*) bad "HEAD: no body" ;; *"HTTP/1.1 200"*) ok ;; *) bad "HEAD: raw request answered" ;; esac

# --- everything else is refused ---------------------------------------------
expect "wrong token: 404" 404 "$(get "http://127.0.0.1:$PORT/ffffffffffffffffffffffffffffffff/page.html")"
expect "wrong name: 404" 404 "$(get "http://127.0.0.1:$PORT/$TOKEN/other.html")"
expect "no token: 404" 404 "$(get "http://127.0.0.1:$PORT/page.html")"
expect "root: 404" 404 "$(get "http://127.0.0.1:$PORT/")"
expect "extra path: 404" 404 "$(get "http://127.0.0.1:$PORT/$TOKEN/page.html/extra")"
expect "traversal: 404" 404 "$(get --path-as-is "http://127.0.0.1:$PORT/$TOKEN/../page.html")"
expect "foreign Host: 421" 421 "$(get -H 'Host: evil.example' "$base")"
expect "foreign Host with the port: 421" 421 "$(get -H "Host: evil.example:$PORT" "$base")"
expect "Host with another port: 421" 421 "$(get -H "Host: 127.0.0.1:$((PORT + 1))" "$base")"
expect "no Host header: 421" 421 "$(get -H 'Host:' "$base")"
expect "POST: 405" 405 "$(get -X POST "$base")"
expect "PUT: 405" 405 "$(get -X PUT -d x "$base")"
expect "DELETE: 405" 405 "$(get -X DELETE "$base")"
expect "still serving after refusals: 200" 200 "$(get "$base")"

# --- a stalled client does not shut out the next one -------------------------
(exec 4<>"/dev/tcp/127.0.0.1/$PORT"; sleep 6) &
sleep 0.3
start_t=$SECONDS
expect "stalled client then a request: 200" 200 "$(get "$base")"
[ $((SECONDS - start_t)) -le 9 ] && ok || bad "stalled client: request waited too long"
kill "$PID" 2>/dev/null

# --- binary integrity --------------------------------------------------------
start "$tmp/blob.png" blob.png image/png 60
expect "binary GET: 200" 200 "$(get "http://127.0.0.1:$PORT/$TOKEN/blob.png")"
cmp -s "$tmp/out" "$tmp/blob.png" && ok || bad "binary GET: bytes are identical"
kill "$PID" 2>/dev/null

# --- the image viewer -----------------------------------------------------------
# The copier is a stub that records its arguments, and fails while $tmp/copier-fails exists.
mkdir -p "$tmp/dl"
cat > "$tmp/copier.sh" <<EOF
printf '%s\n' "\$@" > "$tmp/copied"
[ ! -e "$tmp/copier-fails" ]
EOF
COPIER=(/bin/sh "$tmp/copier.sh")
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/page.html" page.html "text/html; charset=utf-8" 5 "$tmp/dl" "${COPIER[@]}" >/dev/null 2>&1
expect "viewer of a page: exit 64" 64 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/blob.png" blob.png image/svg+xml 5 "$tmp/dl" "${COPIER[@]}" >/dev/null 2>&1
expect "viewer of an svg: exit 64" 64 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/blob.png" blob.png image/png 5 dl "${COPIER[@]}" >/dev/null 2>&1
expect "viewer, relative downloads: exit 64" 64 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/blob.png" blob.png image/png 5 "$tmp/dl" >/dev/null 2>&1
expect "viewer without a copier: exit 64" 64 $?
"$PERL" "$SERVE" 40001 "$TOKEN" "$tmp/blob.png" blob.png image/png 5 "$tmp/dl" sh "$tmp/copier.sh" >/dev/null 2>&1
expect "viewer, relative copier: exit 64" 64 $?

start "$tmp/blob.png" blob.png image/png 60 "$tmp/dl" "${COPIER[@]}"
vbase="http://127.0.0.1:$PORT/$TOKEN"
post() { # path [curl args...]
  local p=$1; shift
  curl -s --max-time 8 -o "$tmp/out" -w '%{http_code}' -X POST "$@" "$vbase/$p"
}

expect "viewer page: 200" 200 "$(get "$vbase/blob.png")"
grep -q 'src="raw/blob.png"' "$tmp/out" && ok || bad "viewer page: shows raw/NAME"
grep -q 'Copy image' "$tmp/out" && grep -q 'Save to Downloads' "$tmp/out" && ok || bad "viewer page: has both buttons"
vhdr="$(curl -s --max-time 8 -D - -o /dev/null "$vbase/blob.png" | tr -d '\r')"
case "$vhdr" in *"Content-Type: text/html; charset=utf-8"*) ok ;; *) bad "viewer page: content type" ;; esac
case "$vhdr" in *"Content-Security-Policy: default-src 'none'"*) ok ;; *) bad "viewer page: CSP" ;; esac
expect "viewer raw image: 200" 200 "$(get "$vbase/raw/blob.png")"
cmp -s "$tmp/out" "$tmp/blob.png" && ok || bad "viewer raw image: bytes are identical"
rhdr="$(curl -s --max-time 8 -D - -o /dev/null "$vbase/raw/blob.png" | tr -d '\r')"
case "$rhdr" in *"Content-Type: image/png"*) ok ;; *) bad "viewer raw image: content type" ;; esac
expect "viewer, other raw name: 404" 404 "$(get "$vbase/raw/other.png")"
expect "viewer, POST to the page: 405" 405 "$(post blob.png -H 'X-Remote-Open: 1')"
expect "viewer, GET of copy: 405" 405 "$(get "$vbase/copy")"
expect "viewer, GET of save: 405" 405 "$(get "$vbase/save")"

rm -f "$tmp/copied"
expect "copy: 200" 200 "$(post copy -H 'X-Remote-Open: 1' -H "Origin: http://127.0.0.1:$PORT")"
expect "copy: answers ok" '{"ok":true}' "$(cat "$tmp/out")"
expect "copy: the copier got the file" "$tmp/blob.png" "$(cat "$tmp/copied" 2>/dev/null)"
rm -f "$tmp/copied"
expect "copy without the header: 403" 403 "$(post copy)"
expect "copy from another origin: 403" 403 "$(post copy -H 'X-Remote-Open: 1' -H 'Origin: http://evil.example')"
expect "copy from another port: 403" 403 "$(post copy -H 'X-Remote-Open: 1' -H "Origin: http://127.0.0.1:$((PORT + 1))")"
expect "copy with a foreign Host: 421" 421 "$(post copy -H 'X-Remote-Open: 1' -H 'Host: evil.example')"
[ ! -e "$tmp/copied" ] && ok || bad "refused copies never ran the copier"
touch "$tmp/copier-fails"
expect "a failing copier: 500" 500 "$(post copy -H 'X-Remote-Open: 1')"
grep -q '"ok":false' "$tmp/out" && ok || bad "a failing copier: answers not ok"
rm -f "$tmp/copier-fails"

expect "save: 200" 200 "$(post save -H 'X-Remote-Open: 1')"
expect "save: answers the name" '{"ok":true,"name":"blob.png"}' "$(cat "$tmp/out")"
cmp -s "$tmp/dl/blob.png" "$tmp/blob.png" && ok || bad "save: bytes are identical"
printf 'mine' > "$tmp/dl/blob (2).png"
expect "save again: 200" 200 "$(post save -H 'X-Remote-Open: 1')"
expect "save again: a name no file has" '{"ok":true,"name":"blob (3).png"}' "$(cat "$tmp/out")"
cmp -s "$tmp/dl/blob (3).png" "$tmp/blob.png" && ok || bad "save again: bytes are identical"
cmp -s "$tmp/dl/blob.png" "$tmp/blob.png" && ok || bad "save again: the first copy is untouched"
expect "save again: an existing file is untouched" mine "$(cat "$tmp/dl/blob (2).png")"
expect "save without the header: 403" 403 "$(post save)"
expect "save without the header: no new file" 3 "$(find "$tmp/dl" -type f | wc -l | tr -d ' ')"
rm -rf "$tmp/dl"
expect "save with no Downloads folder: 500" 500 "$(post save -H 'X-Remote-Open: 1')"
grep -q 'no Downloads folder' "$tmp/out" && ok || bad "save with no Downloads folder: says so"
kill "$PID" 2>/dev/null

# --- the port is taken --------------------------------------------------------
start "$tmp/page.html" page.html text/html 60
busy="$PORT"
"$PERL" "$SERVE" "$busy" "$TOKEN" "$tmp/page.html" page.html text/html 5 >/dev/null 2>&1
expect "port already in use: exit 66" 66 $?
kill "$PID" 2>/dev/null

# --- it leaves by itself ------------------------------------------------------
start "$tmp/page.html" page.html text/html 2
get "http://127.0.0.1:$PORT/$TOKEN/page.html" >/dev/null
sleep 4
if kill -0 "$PID" 2>/dev/null; then
  bad "idle: still running after the idle time"
  kill "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
else
  ok
  wait "$PID" 2>/dev/null; expect "idle: exits 0" 0 $?
fi

echo "serve.sh: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
