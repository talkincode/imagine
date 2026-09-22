#!/bin/sh
# End-to-end check of the generation paths that unit tests cannot reach: the
# real HTTP client, the async create -> poll -> download loop, file writes and
# `--json` output. A local test double (scripts/mock_providers.py) stands in for
# Volcengine Ark and Google Gemini, so this needs no network and no credential.
#
#   scripts/e2e.sh                  # builds with `zig build` first
#   scripts/e2e.sh zig-out/bin/imagine
#
# Requires python3 (for the mock) and a POSIX shell. Exits non-zero on failure.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
bin=${1:-}
if [ -z "$bin" ]; then
    (cd "$root" && zig build)
    bin="$root/zig-out/bin/imagine"
fi
bin=$(cd "$(dirname "$bin")" && pwd)/$(basename "$bin")

work=$(mktemp -d)
mock_pid=""
cleanup() {
    [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

python3 "$root/scripts/mock_providers.py" 0 "$work/requests.log" > "$work/port" &
mock_pid=$!
# Wait for the port line (the mock binds port 0 and reports what it got).
i=0
while [ ! -s "$work/port" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
port=$(cat "$work/port")
[ -n "$port" ] || { echo "mock provider did not start"; exit 1; }
base="http://127.0.0.1:$port"

cat > "$work/config.toml" <<TOML
output_dir = "$work/out"
poll_interval = 1
task_timeout = 30

[models."seedance"]
backend = "seedance"
api_model = "doubao-seedance-2-5-260628"
[[models."seedance".endpoints]]
base_url = "$base/api/v3/contents/generations/tasks"
api_key = "ark-test-key"
[models."seedance".defaults]
duration = 5
resolution = "720p"

[models."seedance-fail"]
backend = "seedance"
api_model = "m"
[[models."seedance-fail".endpoints]]
base_url = "$base/fail/contents/generations/tasks"
api_key = "k"

[models."seedance-slow"]
backend = "seedance"
api_model = "m"
[[models."seedance-slow".endpoints]]
base_url = "$base/slow/contents/generations/tasks"
api_key = "k"

[models."omni"]
backend = "gemini_video"
api_model = "gemini-omni-1.1-flash"
[[models."omni".endpoints]]
base_url = "$base/v1beta/interactions"
api_key = "goog-test-key"
auth = "google_api_key"

[models."omni-bad-key"]
backend = "gemini_video"
api_model = "m"
[[models."omni-bad-key".endpoints]]
base_url = "$base/array-error/interactions"
api_key = "k"
auth = "google_api_key"

[models."plain-image"]
backend = "openai_image"
api_model = "m"
[[models."plain-image".endpoints]]
base_url = "$base/api/v3/images/generations"
api_key = "k"

[models."seedream"]
backend = "volcengine_image"
api_model = "doubao-seedream-5-0-260128"
[[models."seedream".endpoints]]
base_url = "$base/api/v3/images/generations"
api_key = "ark-test-key"
[models."seedream".defaults]
size = "2K"
TOML

mkdir -p "$work/out"
printf 'PNGDATA' > "$work/first.png"
cat > "$work/jobs.json" <<JSON
{ "jobs": [
  { "model": "seedance", "prompt": "a fox", "output": "$work/out/b1.mp4",
    "duration": 3, "resolution": "480p", "ratio": "9:16" },
  { "model": "seedream", "prompt": "a city", "output": "$work/out/b2.png", "n": 2 },
  { "model": "omni", "prompt": "a marble", "output": "$work/out/b3.mp4",
    "image": "$work/first.png", "resolution": "1080p" }
] }
JSON

pass=0
fail=0
# check <label> <expected> <actual>
check() {
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1)); echo "ok   $1"
    else
        fail=$((fail + 1)); echo "FAIL $1: want '$2', got '$3'"
    fi
}
# field <json-file> <python-expression over d>
field() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print($2)" "$1"; }
# exit code of the last command, as 0/1 (for checks that only distinguish
# success from failure). Checks asserting a specific code compare it raw.
rc() { if [ "$1" -eq 0 ]; then echo 0; else echo 1; fi; }

echo "--- seedance: create -> poll -> download"
"$bin" generate -m seedance -p "a fox in snow" --ratio 16:9 -o "$work/out/fox.mp4" \
    --config "$work/config.toml" --json > "$work/r.json"; rc_seed=$?
check "exit code" 0 "$(rc $rc_seed)"
check "ok" True "$(field "$work/r.json" "d['ok']")"
check "media" video "$(field "$work/r.json" "d['media']")"
check "asset path" "$work/out/fox.mp4" "$(field "$work/r.json" "d['videos'][0]['path']")"
check "image array is empty" 0 "$(field "$work/r.json" "len(d['images'])")"
check "downloaded bytes" "SEEDANCE-MP4-BYTES" "$(cat "$work/out/fox.mp4")"
check "create used bearer auth" "Bearer ark-test-key" \
    "$(python3 -c "
import json,sys
for line in open('$work/requests.log'):
    r = json.loads(line)
    if r['method'] == 'POST' and r['path'].endswith('/tasks'):
        print(r['authorization']); break
")"
check "create body shape" 'doubao-seedance-2-5-260628 16:9 720p 5' \
    "$(python3 -c "
import json,sys
for line in open('$work/requests.log'):
    r = json.loads(line)
    if r['method'] == 'POST' and r['path'].endswith('/tasks'):
        b = json.loads(r['body'])
        print(b['model'], b['ratio'], b['resolution'], b['duration']); break
")"

echo "--- gemini omni: inline first frame, Files poll, authenticated download"
"$bin" generate -m omni -p "x" --image "$work/first.png" --duration 5 \
    -o "$work/out/omni.mp4" --config "$work/config.toml" --json > "$work/r.json"; rc_omni=$?
check "exit code" 0 "$(rc $rc_omni)"
check "downloaded bytes" "GEMINI-OMNI-MP4-BYTES" "$(cat "$work/out/omni.mp4")"
check "inline image + uri delivery" "image/png uri" \
    "$(python3 -c "
import json,sys
for line in open('$work/requests.log'):
    r = json.loads(line)
    if r['method'] == 'POST' and r['path'] == '/v1beta/interactions':
        b = json.loads(r['body'])
        img = [p for p in b['input'] if p['type'] == 'image'][0]
        print(img['mime_type'], b['response_format']['delivery']); break
")"
check "download carried the api key" "goog-test-key" \
    "$(python3 -c "
import json,sys
for line in open('$work/requests.log'):
    r = json.loads(line)
    if r['method'] == 'GET' and ':download' in r['path']:
        print(r['goog_api_key']); break
")"

echo "--- gemini omni: URL first frame is fetched and mime-sniffed"
"$bin" generate -m omni -p "x" --image "$base/cdn/first-frame" -o "$work/out/url.mp4" \
    --config "$work/config.toml" --json > "$work/r.json"; rc_url=$?
check "exit code" 0 "$(rc $rc_url)"
check "sniffed png" "image/png" \
    "$(python3 -c "
import json,sys
for line in open('$work/requests.log'):
    r = json.loads(line)
    if r['method'] == 'POST' and r['path'] == '/v1beta/interactions':
        b = json.loads(r['body'])
        print([p for p in b['input'] if p['type'] == 'image'][0]['mime_type']); break
")"

echo "--- volcengine image: synchronous, watermark off"
"$bin" generate -m seedream -p "a city" --no-watermark -o "$work/out/city.png" \
    --config "$work/config.toml" --json > "$work/r.json"; rc_img=$?
check "exit code" 0 "$(rc $rc_img)"
check "media" image "$(field "$work/r.json" "d['media']")"
check "downloaded bytes" "SEEDREAM-PNG-BYTES" "$(cat "$work/out/city.png")"
check "body has size/watermark, no seed or n" "2K False True" \
    "$(python3 -c "
import json,sys
for line in open('$work/requests.log'):
    r = json.loads(line)
    if r['method'] == 'POST' and r['path'].endswith('/images/generations'):
        b = json.loads(r['body'])
        print(b['size'], b['watermark'], 'seed' not in b and 'n' not in b); break
")"

echo "--- -n fans out into independent tasks with numbered paths"
"$bin" generate -m seedance -p x -n 2 -o "$work/out/two.mp4" -c 2 \
    --config "$work/config.toml" --json > "$work/r.json"; rc_n=$?
check "exit code" 0 "$(rc $rc_n)"
check "numbered paths" "['$work/out/two-1.mp4', '$work/out/two-2.mp4']" \
    "$(field "$work/r.json" "[v['path'] for v in d['videos']]")"

echo "--- batch: mixed video and image jobs"
"$bin" batch "$work/jobs.json" --config "$work/config.toml" -c 3 --json > "$work/r.json"; rc_batch=$?
check "exit code" 0 "$(rc $rc_batch)"
check "task count" 4 "$(field "$work/r.json" "len(d['tasks'])")"
check "per-task media" "['video', 'image', 'image', 'video']" \
    "$(field "$work/r.json" "[t['media'] for t in d['tasks']]")"
check "batch job override applied" "480p" \
    "$(python3 -c "
import json,sys
for line in open('$work/requests.log'):
    r = json.loads(line)
    if r['method'] == 'POST' and r['path'].endswith('/tasks'):
        b = json.loads(r['body'])
        if b.get('resolution') == '480p':
            print(b['resolution']); break
")"

echo "--- provider-side failure (HTTP 200 + status failed)"
# Expected to fail, so `set -e` is suspended around it.
set +e
"$bin" generate -m seedance-fail -p x -o "$work/out/fail.mp4" \
    --config "$work/config.toml" --json > "$work/r.json"
rc_fail=$?
set -e
check "exit code" 1 "$(rc $rc_fail)"
check "ok=false" False "$(field "$work/r.json" "d['ok']")"
check "provider message passed through" True \
    "$(field "$work/r.json" "'sensitive information' in d['errors'][0] and 'cgt-fail' in d['errors'][0]")"

echo "--- timeout is bounded and reported"
start=$(date +%s)
set +e
"$bin" generate -m seedance-slow -p x -o "$work/out/slow.mp4" \
    --config "$work/config.toml" --poll-interval 1 --timeout 3 --json > "$work/r.json"
rc_slow=$?
set -e
elapsed=$(( $(date +%s) - start ))
check "exit code" 1 "$(rc $rc_slow)"
check "timeout reported" True "$(field "$work/r.json" "'did not finish within 3s' in d['errors'][0]")"
check "gave up within 6s" True "$(if [ "$elapsed" -le 6 ]; then echo True; else echo False; fi)"

echo "--- ephemeral env: credential default follows the backend"
env -u GEMINI_API_KEY -u ARK_API_KEY HOME="$work" \
    IMAGINE_BASE_URL="$base/api/v3/contents/generations/tasks" \
    IMAGINE_MODEL=doubao-seedance-2-5-260628 IMAGINE_BACKEND=seedance ARK_API_KEY=k \
    "$bin" generate -p "a fox" --duration 4 -o "$work/out/eph.mp4" \
    --poll-interval 1 --timeout 20 --json > "$work/r.json"; rc_eph=$?
check "exit code" 0 "$(rc $rc_eph)"
check "no config file needed" True "$(field "$work/r.json" "d['ok']")"
check "missing-key hint names ARK_API_KEY" True \
    "$(env -u GEMINI_API_KEY -u ARK_API_KEY HOME="$work" \
        IMAGINE_BASE_URL="$base/x" IMAGINE_MODEL=m IMAGINE_BACKEND=seedance \
        "$bin" models 2>&1 | grep -q ARK_API_KEY && echo True || echo False)"

echo "--- built-in presets: listed and callable without any config file"
check "presets listed with media" True \
    "$(env -u GEMINI_API_KEY -u ARK_API_KEY HOME="$work" "$bin" models --json | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(any(m['source'] == 'preset' and m['media'] == 'video' and m['backend'] == 'seedance' for m in d))
")"
check "preset run reports the missing credential" True \
    "$(env -u GEMINI_API_KEY -u ARK_API_KEY HOME="$work" \
        "$bin" generate -m doubao-seedance-2-5-260628 -p x -o "$work/x.mp4" --json 2>&1 |
        grep -q 'set \$ARK_API_KEY' && echo True || echo False)"

echo "--- error envelopes: array-wrapped (Gemini) and unsupported --image"
set +e
"$bin" generate -m omni-bad-key -p x -o "$work/out/bad.mp4" --config "$work/config.toml" --json > "$work/r.json"
rc_bad=$?
set -e
check "array-wrapped error exit code" 1 "$(rc $rc_bad)"
check "array-wrapped error message" True \
    "$(field "$work/r.json" "'API key not valid' in d['errors'][0]")"

set +e
"$bin" generate -m plain-image -p x --image "$work/first.png" -o "$work/out/na.png" \
    --config "$work/config.toml" > "$work/unsupported.txt" 2>&1
rc_unsup=$?
set -e
check "--image on a backend that ignores it" 2 "$rc_unsup"
check "unsupported --image message" True \
    "$(grep -q 'takes no --image input' "$work/unsupported.txt" && echo True || echo False)"

echo "--- batch: preset names resolve without a config file"
cat > "$work/preset-jobs.json" <<JSON
{ "jobs": [ { "model": "doubao-seedance-2-5-260628", "prompt": "x",
             "output": "$work/out/preset.mp4", "duration": 3 } ] }
JSON
set +e
env -u GEMINI_API_KEY HOME="$work/none" ARK_API_KEY=k "$bin" batch "$work/preset-jobs.json" \
    --json > "$work/r.json" 2>&1
rc_preset=$?
set -e
# No network here, so this fails at the provider — what matters is that the job
# resolved the preset name instead of reporting "unknown model".
check "preset job resolved (not unknown model)" True \
    "$(python3 -c "
import json
d = json.load(open('$work/r.json'))
print(not any('unknown model' in str(t.get('err')) for t in d.get('tasks', [])))
")"

echo "--- --poll-interval/--timeout are validated for batch too"
set +e
"$bin" batch "$work/jobs.json" --timeout 0 --config "$work/config.toml" > "$work/zero.txt" 2>&1
rc_zero=$?
set -e
check "batch --timeout 0 is a usage error" 2 "$rc_zero"

echo "--- --dry-run shows the create body and the poll settings"
"$bin" generate -m omni -p x --image "$work/first.png" --dry-run \
    --config "$work/config.toml" > "$work/dry.txt" 2>&1
check "media shown" True "$(grep -q 'media:    video' "$work/dry.txt" && echo True || echo False)"
check "poll settings shown" True "$(grep -q 'giving up after' "$work/dry.txt" && echo True || echo False)"
check "inlined base64 elided" True \
    "$(grep -q 'bytes of base64 elided' "$work/dry.txt" && echo True || echo False)"

echo
echo "e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
