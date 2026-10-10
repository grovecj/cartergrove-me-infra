#!/usr/bin/env bash
# Prints, as a JSON array, the root modules affected by the commits between two
# refs, e.g. ["shared","projects/games"]. The Terraform workflow turns that
# array into a job matrix, so a root module nobody touched gets no job at all.
#
# Usage: changed-roots.sh <base-sha> <head-sha>
#
# A root module counts as changed when:
#   - a file inside its directory changed (including e.g. projects/games/hub/), or
#   - a module it calls (modules/<name>/) changed, or
#   - anything under .github/ changed, so edits to CI are tried on every root.
# A base of all zeros (a newly pushed branch) also means "everything".
set -euo pipefail

base="$1"
head="$2"

# Root modules are the directories whose versions.tf declares a backend.
# Plain modules under modules/ have a versions.tf too, but no backend.
# "shared" is listed first, since projects read its outputs; the workflow
# applies it in its own job before them. (It applies "monitoring" before the
# projects too, picking it out by name, so its place in this list is free.)
mapfile -t all_roots < <(
  git ls-files '*versions.tf' | while read -r file; do
    if grep -q 'backend "' "$file"; then dirname "$file"; fi
  done | sort | awk '$0 == "shared" { print; next } { rest[++n] = $0 } END { for (i = 1; i <= n; i++) print rest[i] }'
)

# Directory names never contain quotes, so plain string-joining is valid JSON.
to_json() {
  local json="" item
  for item in "$@"; do json+="${json:+,}\"$item\""; done
  echo "[$json]"
}

if [[ "$base" =~ ^0+$ ]]; then
  to_json "${all_roots[@]}"
  exit 0
fi

# Three dots: only what changed on the head side since the two diverged.
mapfile -t changed_files < <(git diff --name-only "$base...$head")

if printf '%s\n' "${changed_files[@]}" | grep -q '^\.github/'; then
  to_json "${all_roots[@]}"
  exit 0
fi

# Names of the reusable modules that changed (modules/<name>/...).
mapfile -t changed_modules < <(
  printf '%s\n' "${changed_files[@]}" | sed -n 's#^modules/\([^/]*\)/.*#\1#p' | sort -u
)

affected=()
for root in "${all_roots[@]}"; do
  if printf '%s\n' "${changed_files[@]}" | grep -q "^$root/"; then
    affected+=("$root")
    continue
  fi
  for module in "${changed_modules[@]}"; do
    # Callers reference it as source = "../../modules/<name>" (or "../modules/<name>").
    if grep -qs "modules/$module\"" "$root"/*.tf; then
      affected+=("$root")
      break
    fi
  done
done

to_json "${affected[@]}"
