#!/bin/sh
set -eu
mode=$1
shift
adapter=$1
shift
tmp=$1
shift
mkdir -p "$tmp"
tmp=$(cd "$tmp" && pwd -P)
gate=$tmp/gate
marker=$tmp/child-exited
out=$tmp/out
report=${BUCK2_NEXTEST_EXPORT_DESTINATION:-$tmp/exported.xml}
trusted=$tmp/trusted.xml
: >"$gate"
case "$mode" in
    pass) filter='test(=pass_case)'; timeout_seconds=0 ;;
    fail) filter='test(=fail_case)'; timeout_seconds=0 ;;
    timeout) filter='test(=timeout_case)'; timeout_seconds=1 ;;
    *) printf 'invalid mode: %s\n' "$mode" >&2; exit 2 ;;
esac
BUCK2_NEXTEST_EXPORT_FAULT_GATE="$gate" BUCK2_NEXTEST_EXPORT_FAULT_MARKER="$marker" "$adapter" "$@" --junit-report "$report" --profile ci --filter "$filter" --no-tests auto --report-skipped default --timeout-seconds "$timeout_seconds" >"$out" 2>&1 &
pid=$!
while [ ! -s "$marker" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" || true; cat "$out"; exit 1; }
done
internal=$(sed -n '1p' "$marker")
raw=$(sed -n '2p' "$marker")
[ -f "$internal" ]
cp "$internal" "$trusted"
case "${BUCK2_NEXTEST_EXPORT_FAULT_ACTION:-remove}" in
    capture) ;;
    remove) mv "$internal" "$internal.removed" ;;
    malformed) printf '%s\n' '<testsuites' >"$internal" ;;
    *) printf 'invalid fault action\n' >&2; exit 2 ;;
esac
rm -f "$gate"
set +e
wait "$pid"
status=$?
set -e
if [ "${BUCK2_NEXTEST_EXPORT_FAULT_ACTION:-remove}" = capture ]; then
    [ "$status" -eq "$raw" ] || { cat "$out"; exit 1; }
    [ -s "$report" ]
    trusted_digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$trusted")
    exported_digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$report")
    [ "$trusted_digest" = "$exported_digest" ]
else
    [ "$status" -eq 3 ] || { cat "$out"; printf 'expected adapter status 3, got %s\n' "$status" >&2; exit 1; }
    grep -F "raw nextest status=$raw" "$out" >/dev/null
    grep -F 'export error:' "$out" >/dev/null
    [ ! -e "$report" ]
fi
[ "$(grep -c 'cleanup=once' "$out")" -eq 1 ]
printf '%s\n' "$raw"
