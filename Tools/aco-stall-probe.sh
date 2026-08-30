#!/bin/bash
# ACO first-world-load stall probe.
#
# Separates the live hypotheses for the black screen without guessing:
#   shader compilation  -> the .dxvk-cache file keeps growing, dxvk-cache/dxvk-cs
#                          threads are hot in the sample
#   asset streaming     -> sustained read throughput on the external game volume,
#                          cache size flat, stacks parked in file reads
#   network wait        -> bytes moving, or a socket stuck in SYN_SENT, while cache
#                          and disk are both flat. This is the case the 00:58 run
#                          could not distinguish, because it measured no network at
#                          all: the process was alive, heartbeating and 100% idle,
#                          which is exactly what waiting on a Ubisoft content check
#                          looks like. This title can sit a long time on
#                          "Checking for Additional Content".
#
# No sudo required. Run it while the game sits on the black screen.
set -uo pipefail

SECONDS_TO_WATCH="${1:-120}"
SAMPLES="${2:-2}"          # 10s `sample` captures at the end of the window; 0 to skip
BOTTLE="${FLY_BOTTLE:-$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF}"
CACHE="/Volumes/SSD1TB/SteamLibrary/steamapps/shadercache/812140/DXVK_state_cache/ACOdyssey.dxvk-cache"
DXVK_LOG_DIR="$BOTTLE/drive_c/fly/logs"
GAME_VOL="/Volumes/SSD1TB"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$HOME/Library/Logs/com.fly.gaming/aco-stall-$STAMP"
mkdir -p "$OUT"

PID="${FLY_PROBE_PID:-$(pgrep -f 'ACOdyssey\.exe' | head -1)}"
if [ -z "$PID" ]; then
  echo "No ACOdyssey.exe process found — start the game first." >&2
  exit 1
fi
DEV=$(df "$GAME_VOL" | tail -1 | awk '{print $1}' | sed 's#/dev/##; s#s[0-9]*$##')

# iostat does not track the external volume on this machine, so read the kernel's
# own per-device byte counters instead.
disk_read_bytes() {
  ioreg -c IOBlockStorageDriver -r -l -w0 2>/dev/null | awk -v want="$1" '
    /\+-o IOBlockStorageDriver/ { stats="" }
    /"Statistics" =/ { stats=$0 }
    /"BSD Name" = / {
      n=$0; sub(/.*"BSD Name" = "/,"",n); sub(/".*/,"",n)
      if (n==want && stats!="") {
        r=stats; sub(/.*"Bytes \(Read\)"=/,"",r); sub(/[^0-9].*/,"",r); print r; exit
      }
    }'
}

cache_size() { [ -f "$CACHE" ] && stat -f %z "$CACHE" || echo 0; }

# Host-wide interface counters. Deliberately not `nettop -P -p <pid>`: its per-process
# figures are not monotonic here and produced negative "deltas" in testing. These are
# system-wide, so read them as "is this machine transferring anything at all", and use
# the per-socket queues and states below for anything process-specific.
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
if_bytes() {
  netstat -ib 2>/dev/null | awk -v i="$IFACE" '$1==i && $3 ~ /Link/ {print $7, $10; exit}'
}

# Socket states matter more than throughput for a hang: a wait on an unreachable endpoint
# shows zero bytes and a socket parked in SYN_SENT.
sock_summary() {
  lsof -nP -p "$PID" 2>/dev/null | awk '
    /TCP/ {
      s=$NF; gsub(/[()]/,"",s)
      if (s=="ESTABLISHED") e++; else if (s=="SYN_SENT") y++; else o++
    }
    END { printf "%de/%dsyn/%do", e+0, y+0, o+0 }'
}

# Largest Recv-Q / Send-Q across this process's TCP sockets. Non-zero and stuck means
# data is queued and not moving — the clearest per-process signal of a blocked transfer.
sock_queues() {
  local ports
  ports=$(lsof -nP -p "$PID" 2>/dev/null | grep TCP \
    | grep -oE '(127\.0\.0\.1|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|\*):[0-9]+' \
    | cut -d: -f2 | sort -u | tr '\n' '|' | sed 's/|$//')
  [ -z "$ports" ] && { echo "-/-"; return; }
  netstat -an -p tcp 2>/dev/null | awk -v p="^($ports)\$" '
    NR>2 { n=split($4,a,"."); if (a[n] ~ p) { if ($2+0>r) r=$2+0; if ($3+0>s) s=$3+0 } }
    END { printf "%d/%d", r+0, s+0 }'
}

echo "pid=$PID  volume=$GAME_VOL ($DEV)  watching ${SECONDS_TO_WATCH}s  ->  $OUT"
echo

START_CACHE=$(cache_size)
START_READ=$(disk_read_bytes "$DEV")
read -r START_NET_IN START_NET_OUT <<<"$(if_bytes)"
START_NET_IN=${START_NET_IN:-0}; START_NET_OUT=${START_NET_OUT:-0}
PREV_NET_IN=$START_NET_IN
PREV_NET_OUT=$START_NET_OUT
printf "%-10s %-9s %-13s %-9s %-11s %-11s %-7s %-11s %s\n" \
  clock elapsed cache_bytes new_pipes read_MB/s host_net_KB/s cpu% socks_e/syn/o rq/sq state \
  | tee "$OUT/timeline.txt"
T_START=$(date +%s)
ELAPSED=0
PREV_CACHE=$START_CACHE
PREV_READ=$START_READ
PREV_T=$T_START
while [ "$ELAPSED" -lt "$SECONDS_TO_WATCH" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "process exited at ${ELAPSED}s" | tee -a "$OUT/timeline.txt"
    break
  fi
  sleep 10
  read -r NET_IN NET_OUT <<<"$(if_bytes)"
  NET_IN=${NET_IN:-$PREV_NET_IN}; NET_OUT=${NET_OUT:-$PREV_NET_OUT}
  NOW_CACHE=$(cache_size)
  NOW_READ=$(disk_read_bytes "$DEV")
  NOW_T=$(date +%s)
  ELAPSED=$((NOW_T - T_START))
  read -r CPU STATE <<<"$(ps -o %cpu=,state= -p "$PID" | tr -s ' ')"
  # Keep every endpoint we ever saw, so a stuck connection can be named afterwards.
  { echo "--- $(date +%H:%M:%S) ---"; lsof -nP -p "$PID" 2>/dev/null | grep TCP; } >> "$OUT/sockets.txt"
  printf "%-10s %-9s %-13s %-9s %-11s %-11s %-7s %-11s %s\n" \
    "$(date +%H:%M:%S)" "${ELAPSED}s" "$NOW_CACHE" "$((NOW_CACHE - PREV_CACHE))" \
    "$(echo "$NOW_READ $PREV_READ $((NOW_T - PREV_T))" | awk '{printf "%.1f", ($3>0)?($1-$2)/$3/1048576:0}')" \
    "$(echo "$NET_IN $PREV_NET_IN $NET_OUT $PREV_NET_OUT $((NOW_T - PREV_T))" \
        | awk '{printf "%.0f/%.0f", ($5>0)?($1-$2)/$5/1024:0, ($5>0)?($3-$4)/$5/1024:0}')" \
    "$CPU" "$(sock_summary)" "$(sock_queues) $STATE" | tee -a "$OUT/timeline.txt"
  PREV_CACHE=$NOW_CACHE
  PREV_READ=$NOW_READ
  PREV_NET_IN=$NET_IN
  PREV_NET_OUT=$NET_OUT
  PREV_T=$NOW_T
done

# Spaced samples, so a one-off stack isn't mistaken for a steady state.
for n in $(seq 1 "$SAMPLES"); do
  if kill -0 "$PID" 2>/dev/null; then
    sample "$PID" 10 -f "$OUT/sample-$n.txt" >/dev/null 2>&1 || true
    sleep 2
  fi
done

cp -f "$DXVK_LOG_DIR"/*.log "$OUT/" 2>/dev/null || true

END_CACHE=$(cache_size)
END_READ=$(disk_read_bytes "$DEV")
{
  echo "=== verdict inputs ==="
  echo "shader cache: $START_CACHE -> $END_CACHE bytes (delta $((END_CACHE - START_CACHE)))"
  echo "$DEV read:    $(echo "$END_READ $START_READ $ELAPSED" | awk '{printf "%.0f MB over %ss (%.1f MB/s avg)", ($1-$2)/1048576, $3, ($3>0)?($1-$2)/$3/1048576:0}')"
  read -r END_NET_IN END_NET_OUT <<<"$(if_bytes)"
  echo "host net ($IFACE): $(echo "${END_NET_IN:-0} $START_NET_IN ${END_NET_OUT:-0} $START_NET_OUT $ELAPSED" \
    | awk '{printf "%.1f MB in / %.1f MB out over %ss — system-wide, not per-process", ($1-$2)/1048576, ($3-$4)/1048576, $5}')"
  echo "sockets:      $(sock_summary) established/SYN_SENT/other, queues $(sock_queues) (recv/send)"
  echo "              SYN_SENT = a connection never completing. A stuck non-zero queue = data not moving."
  echo
  echo "--- remote endpoints seen ---"
  grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' "$OUT/sockets.txt" 2>/dev/null | sort | uniq -c | sort -rn | head -15
  echo
  echo "--- thread names (sample 2) ---"
  grep -oE "Thread_[0-9]+: [^ ]+" "$OUT/sample-2.txt" 2>/dev/null | cut -d' ' -f2- | sort | uniq -c | sort -rn | head -20
  echo
  echo "--- compile vs file-read frames (sample 2) ---"
  grep -oiE "dxvk-[a-z]+|vkCreate[A-Za-z]+|spirv[A-Za-z]*|NtReadFile|pread(_nocancel)?|__open" \
    "$OUT/sample-2.txt" 2>/dev/null | sort | uniq -c | sort -rn | head -20
  echo
  echo "--- DXVK log tail ---"
  tail -40 "$OUT"/*d3d11.log 2>/dev/null || echo "(no DXVK log — is DXVK_LOG_PATH set for this launch?)"
} | tee "$OUT/verdict.txt"

echo
echo "Full capture: $OUT"
