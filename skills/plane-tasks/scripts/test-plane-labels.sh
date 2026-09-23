#!/usr/bin/env bash
set -euo pipefail

# Offline regression test: curl is replaced with a deterministic API fixture.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mode=${PLANE_MOCK_MODE:?}
method=GET
url=""
data=""
while (($#)); do
  case $1 in
    -X) method=$2; shift 2;;
    -d) data=$2; shift 2;;
    http*) url=$1; shift;;
    *) shift;;
  esac
done
printf '%s %s %s\n' "$method" "$url" "$data" >>"${PLANE_MOCK_LOG:?}"
case "$url" in
  */issues/issue-uuid/)
    if [[ "$method" == PATCH ]]; then printf '{"sequence_id":42,"labels":["old-label","new-label"]}';
    else printf '{"labels":["old-label"]}'; fi ;;
  */issues/?*) printf '{"results":[{"id":"issue-uuid","sequence_id":42}]}' ;;
  */labels/)
    if [[ "$method" == POST ]]; then printf '{"id":"new-label"}';
    elif [[ "$mode" == existing ]]; then printf '{"results":[{"id":"old-label","name":"v1"}]}' ;
    else printf '{"results":[]}'; fi ;;
  *) echo "unexpected URL: $url" >&2; exit 1;;
esac
MOCK
chmod +x "$TMP/curl"
run() {
  : >"$TMP/log"
  PATH="$TMP:$PATH" PLANE_MOCK_MODE="$1" PLANE_MOCK_LOG="$TMP/log" \
    PLANE_API_KEY=test PLANE_BASE_URL=https://plane.test PLANE_WORKSPACE_SLUG=ws \
    "$ROOT/plane-labels.sh" --project project --issue 42 --label "$2" >/dev/null
}
run existing v1
! grep -q '"name"' "$TMP/log" # existing label must not be created
 grep -q '"labels":\["old-label","old-label"\]' "$TMP/log" && exit 1
run missing v2
grep -q 'POST.*labels/' "$TMP/log"
grep -q '"labels":\["old-label","new-label"\]' "$TMP/log"
echo 'plane-labels mocked tests passed'
