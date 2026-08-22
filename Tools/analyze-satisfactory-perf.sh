#!/usr/bin/env bash
# Summarize Satisfactory LoadMap / hitch / pacing signals from FactoryGame.log.
#
# Usage:
#   Tools/analyze-satisfactory-perf.sh
#   Tools/analyze-satisfactory-perf.sh /path/to/FactoryGame.log
#
# Theory check (flat → spike → flat):
#   1. fly play satisfactory-perf --debug
#   2. Watch on-screen unitgraph + Metal HUD during spikes
#   3. Quit → run this script
#   4. Interpret:
#        many Hitch lines, clustered     → consistent hitch cadence (your theory)
#        LoadMap ~52s menu               → still translate/compile bound at load
#        Game ms spikes, GPU idle (HUD)  → CPU/Wine/D3DM/present, not GPU fill
#        GPU ms spikes, HUD GPU busy     → GPU/shader work
#        no Hitch lines but feels bad    → hitch threshold not firing; rely on unitgraph

set -euo pipefail

BOTTLE="${FLY_BOTTLE:-$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF}"
DEFAULT_LOG="$BOTTLE/drive_c/users/crossover/AppData/Local/FactoryGame/Saved/Logs/FactoryGame.log"
LOG="${1:-$DEFAULT_LOG}"

# Prefer rg when available; fall back to grep (macOS PATH often lacks rg).
if command -v rg >/dev/null 2>&1; then
  search() { rg -n "$@" || true; }
  search_count() { rg -c "$@" 2>/dev/null || echo 0; }
  search_i() { rg -n -i "$@" || true; }
  search_count_i() { rg -c -i "$@" 2>/dev/null || echo 0; }
else
  search() { grep -nE "$1" "$2" || true; }
  search_count() { grep -cE "$1" "$2" 2>/dev/null || echo 0; }
  search_i() { grep -niE "$1" "$2" || true; }
  search_count_i() { grep -ciE "$1" "$2" 2>/dev/null || echo 0; }
fi

if [[ ! -f "$LOG" ]]; then
  echo "No log at: $LOG" >&2
  echo "Play once first: .build/release/wyn play satisfactory-perf --debug" >&2
  exit 1
fi

echo "════════════════════════════════════════════════════════"
echo "Satisfactory perf summary"
echo "Log: $LOG"
echo "Size: $(wc -c < "$LOG") bytes  mtime: $(stat -f '%Sm' "$LOG")"
echo "════════════════════════════════════════════════════════"
echo ""

echo "── LoadMap times ──"
out="$(search 'Took .* seconds to LoadMap|LoadMap:' "$LOG")"
[[ -n "$out" ]] && echo "$out" || echo "(none)"
echo ""

echo "── Hitch / stall signals ──"
HITCH_COUNT="$(search_count_i 'hitch|Hitch detected|Game Thread Hitch|stat hitch' "$LOG")"
echo "Matching lines: ${HITCH_COUNT:-0}"
search_i 'hitch|Hitch detected|Game Thread Hitch' "$LOG" | tail -40
echo ""

echo "── Shader / pipeline (compile pressure) ──"
out="$(search 'ShaderPipelineCache|Compiling shader|PSO|LogRHI:.*Batch' "$LOG" | tail -30)"
[[ -n "$out" ]] && echo "$out" || echo "(none)"
echo ""

echo "── Streaming / flush (I/O pressure) ──"
out="$(search 'FlushAsyncLoading|LogStreaming:.*Display' "$LOG" | tail -20)"
[[ -n "$out" ]] && echo "$out" || echo "(none)"
echo ""

echo "── Main-thread starvation (EOS Tick delayed) ──"
out="$(search 'Tick is delayed|TickTracker' "$LOG" | tail -20)"
[[ -n "$out" ]] && echo "$out" || echo "(none)"
echo ""

echo "── Navmesh / long CPU jobs ──"
out="$(search 'build time:|Navmesh bounds' "$LOG" | tail -20)"
[[ -n "$out" ]] && echo "$out" || echo "(none)"
echo ""

echo "── Adapter / RHI (confirm D3DMetal) ──"
out="$(search 'AMD Compatibility|Feature Level|GeForce|Chosen Device|Adapter Name' "$LOG" | tail -20)"
[[ -n "$out" ]] && echo "$out" || echo "(none)"
echo ""

echo "── SynthBenchmark / GPU probe (broken timing = red flag) ──"
out="$(search 'SynthBenchmark|GigaPix|GPU Perf Index' "$LOG" | tail -15)"
[[ -n "$out" ]] && echo "$out" || echo "(none)"
echo ""

echo "── Frame-ish counters (if unit/csv ran) ──"
out="$(search 'FrameTime|frametime|FPS:|stat unit|CSV' "$LOG" | tail -20)"
[[ -n "$out" ]] && echo "$out" || echo "(none — use on-screen unitgraph from satisfactory-perf)"
echo ""

echo "── How to read this ──"
echo "• Regular hitch clusters in the log ≈ your flat→spike cadence."
echo "• During a spike on unitgraph: note which bar jumps (Game / Draw / GPU)."
echo "• Metal HUD GPU idle + Game/Draw spike ⇒ translation/present/CPU, not fill-rate."
echo "• Metal HUD GPU maxed ⇒ GPU/shader; MetalFX may help in-world, not LoadMap."
echo "• EOS 'Tick is delayed' + navmesh build times ⇒ CPU main-thread stalls (matches flat→spike)."
echo "• Disk theory: if FlushAsyncLoading dominates AND local install fixes it → storage."
echo ""
echo "Next: screenshot unitgraph during a spike, then re-run this after quit."
