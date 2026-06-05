#!/usr/bin/env bash
# ci-watch — Đợi CI pipeline (GitLab multi-host hoặc GitHub Actions) của 1 commit
# chạy xong rồi in kết quả gọn. Vòng poll nằm trong bash → khi gọi từ Claude,
# model chỉ thấy kết quả cuối. Log job-failed được tail + strip ANSI.
#
# Usage:
#   ci-watch --provider gitlab --host <host> --project <grp/repo> --ref <branch> [--sha <sha>]
#   ci-watch --provider github               --project <owner/repo> --ref <branch> [--sha <sha>]
#   tuỳ chọn: --poll N (20) --max N (1800) --tail N (40)
#
# Exit: 0 = success | 1 = failed | 2 = timeout / không tìm thấy / lỗi tra cứu.

set -uo pipefail

PROVIDER="" HOST="" PROJECT="" REF="main" SHA="" POLL=20 MAX=1800 TAIL=40
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2;;
    --host)     HOST="$2"; shift 2;;
    --project)  PROJECT="$2"; shift 2;;
    --ref)      REF="$2"; shift 2;;
    --sha)      SHA="$2"; shift 2;;
    --poll)     POLL="$2"; shift 2;;
    --max)      MAX="$2"; shift 2;;
    --tail)     TAIL="$2"; shift 2;;
    *) echo "arg lạ: $1" >&2; shift;;
  esac
done
[[ -n "$PROVIDER" && -n "$PROJECT" ]] || { echo "✗ thiếu --provider/--project"; exit 2; }
strip() { sed -E 's/\x1b\[[0-9;]*[mGKH]//g'; }

# ─────────────────────────── GitLab ───────────────────────────
watch_gitlab() {
  [[ -n "$HOST" ]] && export GITLAB_HOST="$HOST"
  local enc="${PROJECT//\//%2F}" pid="" elapsed=0 status
  local q
  find_pipeline() {
    q="projects/$enc/pipelines?per_page=1"
    if [[ -n "$SHA" ]]; then q="$q&sha=$SHA"; else q="$q&ref=$REF"; fi
    glab api "$q" 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); print(d[0]["id"] if d else "")' 2>/dev/null
  }
  for _ in $(seq 1 6); do pid="$(find_pipeline)"; [[ -n "$pid" ]] && break; sleep 5; done
  [[ -z "$pid" ]] && { echo "✗ GitLab: không thấy pipeline cho ${SHA:-$REF} ($HOST/$PROJECT)"; return 2; }
  echo "⏳ GitLab pipeline #$pid ($HOST/$PROJECT @ $REF) — poll ${POLL}s, max ${MAX}s"
  while :; do
    status="$(glab api "projects/$enc/pipelines/$pid" 2>/dev/null \
              | python3 -c 'import sys,json;print(json.load(sys.stdin).get("status",""))' 2>/dev/null)"
    case "$status" in
      success)            echo "✅ pipeline #$pid SUCCESS (${elapsed}s)"; return 0;;
      failed)             break;;
      canceled|skipped)   echo "⚠️  pipeline #$pid $status (${elapsed}s)"; return 1;;
      ""|null)            echo "✗ mất trạng thái pipeline #$pid"; return 2;;
    esac
    (( elapsed >= MAX )) && { echo "⏱️  timeout ${MAX}s — #$pid còn '$status'"; return 2; }
    sleep "$POLL"; elapsed=$((elapsed+POLL))
  done
  echo "❌ pipeline #$pid FAILED (${elapsed}s) — $HOST/$PROJECT"
  glab api "projects/$enc/pipelines/$pid/jobs?per_page=100" 2>/dev/null > /tmp/ciw_jobs.json
  python3 - "$enc" "$TAIL" <<'PY'
import sys,json,subprocess,re,os
enc,tail=sys.argv[1],int(sys.argv[2])
jobs=json.load(open('/tmp/ciw_jobs.json'))
failed=[j for j in jobs if j['status']=='failed']
print(f"Jobs failed: {', '.join(j['name'] for j in failed) or 'none'}\n")
for j in failed:
    print(f"────── {j['name']} (stage={j['stage']}, id={j['id']}) ──────")
    try:
        tr=subprocess.run(['glab','api',f"projects/{enc}/jobs/{j['id']}/trace"],
                          capture_output=True,text=True,timeout=30,
                          env={**os.environ}).stdout
        tr=re.sub(r'\x1b\[[0-9;]*[mGKH]','',tr)
        print('\n'.join([l for l in tr.splitlines() if l.strip()][-tail:]))
    except Exception as e:
        print(f"(không lấy được trace: {e})")
    print()
PY
  return 1
}

# ─────────────────────────── GitHub ───────────────────────────
watch_github() {
  local elapsed=0 ref_q
  [[ -n "$SHA" ]] && ref_q="head_sha=$SHA" || ref_q="branch=$REF"
  runs_json() { gh api "repos/$PROJECT/actions/runs?$ref_q&per_page=30" 2>/dev/null; }
  # đợi có ít nhất 1 run
  local have=""
  for _ in $(seq 1 6); do
    have="$(runs_json | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("workflow_runs",[])))' 2>/dev/null)"
    [[ "$have" =~ ^[0-9]+$ && "$have" -gt 0 ]] && break; sleep 5
  done
  [[ "$have" =~ ^[0-9]+$ && "$have" -gt 0 ]] || { echo "✗ GitHub: không có workflow run cho ${SHA:-$REF} ($PROJECT) — Actions tắt?"; return 2; }
  echo "⏳ GitHub Actions ($PROJECT @ ${SHA:0:8}${SHA:+ }$REF) — $have run, poll ${POLL}s, max ${MAX}s"
  while :; do
    local verdict
    verdict="$(runs_json | python3 -c 'import sys,json
rs=json.load(sys.stdin)["workflow_runs"]
if not rs: print("none"); sys.exit()
if any(r["status"]!="completed" for r in rs): print("pending")
else:
    bad=[r for r in rs if r["conclusion"] not in ("success","neutral","skipped")]
    print("fail "+" ".join(str(r["id"]) for r in bad) if bad else "ok")' 2>/dev/null)"
    case "$verdict" in
      ok)       echo "✅ tất cả workflow run SUCCESS (${elapsed}s)"; return 0;;
      fail\ *)  echo "❌ workflow run FAILED (${elapsed}s) — $PROJECT"
                for id in ${verdict#fail }; do
                  echo "────── run $id ──────"
                  gh run view "$id" --repo "$PROJECT" --log-failed 2>/dev/null | strip | tail -"$TAIL"
                  echo
                done
                return 1;;
      none|"")  echo "✗ mất trạng thái run ($PROJECT)"; return 2;;
    esac
    (( elapsed >= MAX )) && { echo "⏱️  timeout ${MAX}s ($PROJECT)"; return 2; }
    sleep "$POLL"; elapsed=$((elapsed+POLL))
  done
}

case "$PROVIDER" in
  gitlab) watch_gitlab;;
  github) watch_github;;
  *) echo "✗ provider không hỗ trợ: $PROVIDER"; exit 2;;
esac
