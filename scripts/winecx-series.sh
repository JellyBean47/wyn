# This file is part of Wyn.
#
# Wyn is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Wyn is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Wyn. If not, see https://www.gnu.org/licenses/.
#
# Sourced by build-foss-game-host.sh, stage-runtime.sh and package-sources.sh,
# after runtime-pins.env and a `fail` function.
#
# Wyn's Wine is winecx at WINECX_COMMIT with the patches in patches/winecx/
# applied in name order, and nothing else. A checkout counts only when HEAD is
# the pin and its tracked files are exactly the pin plus the series. The git
# tree hash of that state (WINECX_TREE) is what the build records, what staging
# checks the build against, and what the source archive lets anyone re-derive.

WINECX_PATCH_DIR="${WINECX_PATCH_DIR:-$ROOT/patches/winecx}"
# A missing directory is an error, not an empty series: a rebuild from the
# source archive has to point WINECX_PATCH_DIR at its wine/patches, or it would
# quietly build without them. Checked here, in the sourcing shell, because the
# functions below run inside command substitutions where `fail` cannot stop it.
[[ -d "$WINECX_PATCH_DIR" ]] \
  || fail "$WINECX_PATCH_DIR missing: set WINECX_PATCH_DIR to the winecx patch series"

# The patch files, in the order they apply.
winecx_series() {
  find "$WINECX_PATCH_DIR" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort
}

# Tree hash of WINECX_COMMIT with the series applied, computed in a scratch
# index so the checkout itself is not touched.
winecx_series_tree() {  # repo
  local repo="$1" tmp p tree="" ok=1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/wyn-winecx-index.XXXXXX")"
  if GIT_INDEX_FILE="$tmp/index" git -C "$repo" read-tree "$WINECX_COMMIT"; then
    while IFS= read -r p; do
      if ! GIT_INDEX_FILE="$tmp/index" git -C "$repo" apply --cached "$p"; then
        echo "error: $(basename "$p") does not apply to $WINECX_COMMIT" >&2
        ok=0
        break
      fi
    done < <(winecx_series)
    (( ok )) && tree="$(GIT_INDEX_FILE="$tmp/index" git -C "$repo" write-tree)"
  fi
  rm -rf "$tmp"
  [[ -n "$tree" ]] || return 1
  echo "$tree"
}

# Fail unless the checkout is exactly the pin plus the series; set WINECX_TREE.
winecx_verify() {  # repo
  local repo="$1" head want
  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
  [[ "$head" == "$WINECX_COMMIT" ]] \
    || fail "winecx checkout is $head, pin is $WINECX_COMMIT"
  want="$(winecx_series_tree "$repo")" || fail "patches/winecx does not apply to $WINECX_COMMIT"
  [[ "$(git -C "$repo" write-tree)" == "$want" ]] \
    || fail "the winecx checkout is not $WINECX_COMMIT plus patches/winecx (git -C $repo diff --cached $WINECX_COMMIT)"
  git -C "$repo" diff --quiet \
    || fail "the winecx checkout has changes that are not the patch series (git -C $repo diff)"
  WINECX_TREE="$want"
}

# Bring a clean checkout of the pin to pin + series. A checkout that already
# holds exactly the series is accepted as it is; anything else is refused.
winecx_apply_series() {  # repo
  local repo="$1" p
  if [[ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]]; then
    while IFS= read -r p; do
      echo "    applying $(basename "$p")"
      git -C "$repo" apply --index "$p" || fail "$(basename "$p") does not apply to $WINECX_COMMIT"
    done < <(winecx_series)
  fi
  winecx_verify "$repo"
}

# What a built tree records about its source (share/wine/wyn-winecx-source.txt).
winecx_source_record() {
  local p
  echo "winecx $WINECX_COMMIT"
  echo "tree   $WINECX_TREE"
  while IFS= read -r p; do
    echo "patch  $(shasum -a 256 "$p" | awk '{print $1}')  $(basename "$p")"
  done < <(winecx_series)
}
