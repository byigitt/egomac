#!/usr/bin/env bash
#
# probe-ego.sh — sanity-check every EGO endpoint EGO Mac depends on.
#
# Usage:
#   bash scripts/probe-ego.sh                # default stop=10940, line=481
#   STOP=11524 LINE=523-6 bash scripts/probe-ego.sh
#
# Exits non-zero if any of the four required endpoints stops returning data,
# so it can be wired into CI / a release-day check.
#
# To re-discover new endpoints from a fresh APK, re-run the discovery flow in
# `docs/api-discovery.md`. This script ONLY validates known-good ones.

set -uo pipefail

STOP="${STOP:-10940}"
LINE="${LINE:-481}"
UA_IOS="EGO Cepte/8 CFNetwork/1568.300.101 Darwin/24.0.0"
UA_WEB="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
HOST_API="egocptsrvand.ego.gov.tr"
HOST_WEB="www.ego.gov.tr"

fail=0
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$*"; fail=$((fail+1)); }
note() { printf "  \033[2m· %s\033[0m\n" "$*"; }

probe_json() {
    local label="$1" url="$2" min_size="$3"
    local out; out=$(mktemp)
    local code; code=$(curl -ks --max-time 8 -A "$UA_IOS" -o "$out" -w "%{http_code}" "$url")
    local sz; sz=$(wc -c < "$out" | tr -d ' ')
    if [[ "$code" != "200" ]]; then
        bad "$label  HTTP=$code  size=${sz}b  ($url)"
    elif (( sz < min_size )); then
        bad "$label  too small (${sz}b < ${min_size}b)  ($url)"
    elif ! python3 -c "import json,sys; d=json.load(open('$out')); sys.exit(0 if d.get('status')=='TRUE' else 1)" 2>/dev/null; then
        bad "$label  JSON missing status=TRUE  ($url)"
    else
        local rows; rows=$(python3 -c "import json; print(len(json.load(open('$out')).get('table',[])))")
        ok "$label  ${sz}b, ${rows} rows"
    fi
    rm -f "$out"
}

probe_html_post() {
    local label="$1" url="$2" body="$3" min_size="$4" must_contain="$5"
    local out; out=$(mktemp)
    local code; code=$(curl -ks --max-time 8 -A "$UA_WEB" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Referer: https://${HOST_WEB}/hareketsaatleri" \
        -X POST -o "$out" -w "%{http_code}" --data "$body" "$url")
    local sz; sz=$(wc -c < "$out" | tr -d ' ')
    if [[ "$code" != "200" ]]; then
        bad "$label  HTTP=$code  size=${sz}b  (POST $url)"
    elif (( sz < min_size )); then
        bad "$label  too small (${sz}b < ${min_size}b)"
    elif ! grep -q "$must_contain" "$out"; then
        bad "$label  expected substring '$must_contain' missing"
    else
        ok "$label  ${sz}b"
    fi
    rm -f "$out"
}

echo "=== EGO endpoint health check (stop=$STOP, line=$LINE) ==="
probe_json "FNC=Otobusler&DURAK=$STOP" \
    "https://${HOST_API}/mblSrv14/service.asp?FNC=Otobusler&VER=3.1.0&LAN=tr&DURAK=${STOP}" 50

probe_json "FNC=Otobus&HAT=$LINE&DURAK=$STOP" \
    "https://${HOST_API}/mblSrv14/service.asp?FNC=Otobus&VER=3.1.0&LAN=tr&HAT=${LINE}&DURAK=${STOP}" 50

probe_html_post "AjaxData/HatListesi (full)" \
    "https://${HOST_WEB}/AjaxData/HatListesi" \
    "" 1000 "<option"

probe_html_post "HareketSaatleri hat=$LINE" \
    "https://${HOST_WEB}/HareketSaatleri" \
    "hat_no1=${LINE}" 5000 "Saat Tablosu"

# These are documented as DEAD in docs/api-discovery.md. Confirm they stay dead;
# if any starts returning a body, the discovery doc needs updating.
echo ""
echo "=== Dead endpoints (expected to stay 0b — drift watcher) ==="
for spec in \
    "FNC=Duraklar&QUERY=kizilay" \
    "FNC=DuraktanGecenHatlar&KOD=${STOP}" \
    "FNC=DuraklardanGecisSaatleri&HAT=${LINE}" \
    "FNC=HatAra&QUERY=${LINE}"; do
    out=$(mktemp)
    code=$(curl -ks --max-time 5 -A "$UA_IOS" -o "$out" -w "%{http_code}" \
        "https://${HOST_API}/hibrit/action.asp?${spec}&LAN=tr&VER=4.0.7")
    sz=$(wc -c < "$out" | tr -d ' ')
    if (( sz > 50 )); then
        ok "DRIFT! /hibrit/action.asp?${spec} now returns ${sz}b — investigate"
    else
        note "still dead: ${spec} (${code}, ${sz}b)"
    fi
    rm -f "$out"
done

echo ""
if (( fail > 0 )); then
    echo "✗ $fail check(s) failed"
    exit 1
fi
echo "✓ all required endpoints healthy"
