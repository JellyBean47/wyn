#!/usr/bin/env bash
# Own-session Wine Steam for D3DMetal play. Source from A/B launchers, or:
#   bash scripts/steam-own-session.sh --check
#
# Tight match is Steam\steam.exe / argv0 steam.exe — never FactoryGameSteam.exe
# (pgrep steam.exe matches that) and never steamwebhelper steampath= lines.
#
# Start path: POSIX::setsid + double-fork so steam.exe PPID is 1 and it is not
# in the game's process group. Do not exec the game from the Steam-owning shell
# either — if you do, this start still survives because Steam is already reparented.
# Do not `set -e` here: this file is sourced.

steam_client_up() {
  # Do not `exit 0` on the first hit: with `pipefail`, perl closing early
  # SIGPIPEs ps and the function looks like a miss.
  ps -axo command= | perl -e '
    my $hit = 0;
    while (<STDIN>) {
      s/^\s+//;
      next if /steamwebhelper/i;
      next if /steampath=/i;
      next if /FactoryGameSteam/i;
      $hit = 1 if m{[\\/]Steam[\\/]steam\.exe}i || m{^steam\.exe(?:\s|$)};
    }
    exit($hit ? 0 : 1);
  '
}

# Prints "pid ppid pgid command" for the real Steam client, or nothing.
steam_client_rows() {
  ps -axo pid=,ppid=,pgid=,command= | perl -ne '
    next unless /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$/;
    my ($pid, $ppid, $pgid, $cmd) = ($1, $2, $3, $4);
    $cmd =~ s/^\s+//;
    next if $cmd =~ /steamwebhelper/i;
    next if $cmd =~ /steampath=/i;
    next if $cmd =~ /FactoryGameSteam/i;
    next unless $cmd =~ m{[\\/]Steam[\\/]steam\.exe}i || $cmd =~ m{^steam\.exe(?:\s|$)};
    print "$pid $ppid $pgid $cmd\n";
  '
}

# 0 = Steam is not a child of FactoryGame*. 1 = child-of-game (do not attach).
steam_is_own_session() {
  steam_client_up || return 1
  local row pid ppid pgid
  while read -r pid ppid pgid _; do
    [[ -n "${pid:-}" ]] || continue
    local parent
    parent=$(ps -p "$ppid" -o command= 2>/dev/null || true)
    if printf '%s\n' "$parent" | perl -e 'my $h=0; while (<STDIN>) { $h=1 if /FactoryGame/i } exit($h?0:1)'; then
      return 1
    fi
  done < <(steam_client_rows)
  return 0
}

# Daemonize: setsid + double-fork + ignore HUP. Extra args after the log path
# are passed to steam.exe (e.g. -silent). Requires WINE, STEAM_DIR.
# Always pass -cef-disable-gpu: winecx CEF GPU process crash-loops (black HWND).
# Always pass -cef-in-process-gpu: disable-gpu alone still leaves a black login
# HWND (CEF paints, Wine never gets the frames).
start_own_session_steam() {
  local log="${1:?start_own_session_steam: log path}"
  shift
  case " $* " in
    *" -cef-disable-gpu "*) ;;
    *) set -- "$@" -cef-disable-gpu ;;
  esac
  case " $* " in
    *" -cef-in-process-gpu "*) ;;
    *) set -- "$@" -cef-in-process-gpu ;;
  esac
  : "${WINE:?}" "${STEAM_DIR:?}"
  mkdir -p "$(dirname "$log")"
  echo "Starting own-session FOSS Steam (setsid + double-fork; not a child of this script or the game)"
  STEAM_DIR="$STEAM_DIR" WINE="$WINE" STEAM_LOG="$log" /usr/bin/perl -e '
    use POSIX qw(setsid _exit);
    $SIG{HUP} = "IGNORE";
    my $log = $ENV{STEAM_LOG};
    my $dir = $ENV{STEAM_DIR};
    my $wine = $ENV{WINE};
    defined(my $mid = fork) or die "fork: $!";
    if ($mid) { waitpid($mid, 0); exit($? >> 8); }
    setsid() or die "setsid: $!";
    defined(my $kid = fork) or die "fork2: $!";
    _exit(0) if $kid;
    $SIG{HUP} = "IGNORE";
    chdir $dir or die "chdir $dir: $!";
    open STDIN, "<", "/dev/null" or die $!;
    open STDOUT, ">>", $log or die "open $log: $!";
    open STDERR, ">>&STDOUT";
    exec $wine, "steam.exe", @ARGV or die "exec $wine: $!";
  ' -- "$@"
}

wait_steam_logged_on() {
  local conn="${1:?}"
  local before="${2:-0}"
  local logged=0
  local new
  for _ in $(seq 1 90); do
    if [[ -f "$conn" ]]; then
      new="$(tail -n +"$((before + 1))" "$conn" 2>/dev/null || true)"
      if printf '%s\n' "$new" | perl -e 'my $h=0; while (<STDIN>) { $h=1 if /\[Logged On/ } exit($h?0:1)'; then
        echo "Steam Logged On"
        logged=1
        break
      fi
    fi
    sleep 2
  done
  if [[ "$logged" -ne 1 ]]; then
    echo "REFUSE: Steam did not Logged On in 180s" >&2
    return 4
  fi
  if ! steam_is_own_session; then
    echo "REFUSE: steam.exe is a child of the game — not attaching" >&2
    steam_client_rows >&2 || true
    return 5
  fi
}

print_steam_session() {
  echo "── Steam session ──"
  if ! steam_client_up; then
    echo "steam.exe: not running (tight match)"
    if pgrep -lf 'steam.exe' >/dev/null 2>&1; then
      echo "note: pgrep steam.exe still matches (likely FactoryGameSteam.exe) — ignore that"
    fi
    return 1
  fi
  steam_client_rows
  if steam_is_own_session; then
    echo "session: own-session (not a child of FactoryGame)"
    return 0
  fi
  echo "session: CHILD OF GAME — do not launch another play; do not wineserver -k"
  return 2
}

# After the game wine process returns: Steam must still be the real client.
assert_steam_survived() {
  if steam_client_up && steam_is_own_session; then
    echo "Steam still up after game wine exit (own-session harness OK)"
    return 0
  fi
  echo "FAIL: Steam died or became a child of the game when the game wine exited" >&2
  print_steam_session >&2 || true
  return 6
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    --check|"")
      print_steam_session
      exit $?
      ;;
    *)
      echo "usage: $0 --check" >&2
      exit 2
      ;;
  esac
fi
