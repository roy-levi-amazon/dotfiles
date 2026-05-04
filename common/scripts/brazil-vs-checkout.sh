#!/bin/bash
set -euo pipefail

BMDS="https://brazil-metadata-sso.corp.amazon.com"

# ─────────────────────────────────────────────────────────────────────────────
# Usage
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [--rebase-only] [version-set[@event-id]] [event-id]

Checks out the correct branch and commit for every package in the current
Brazil workspace, matching the given version set (and optional event ID).
If no version set is given, uses the workspace's current version set.
If no event ID is given, the latest is fetched automatically from BMDS.

Options:
    --rebase-only   Don't switch branches. Rebase the current branch onto
                    the commit the version set points to. Useful when you
                    have a feature branch and want to rebase it onto the
                    exact commit in the VS.

Must be run from inside a Brazil workspace (~/projects/<ws>).

Examples:
    $(basename "$0")
    $(basename "$0") --rebase-only
    $(basename "$0") EBSServer/mainline
    $(basename "$0") EBSServer/mainline 6418765464
    $(basename "$0") --rebase-only EBSServer/mainline@6418765464
EOF
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Find workspace root by walking up to packageInfo.
find_workspace_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        [[ -f "$dir/packageInfo" ]] && echo "$dir" && return
        dir=$(dirname "$dir")
    done
    return 1
}

# Read the current event ID from the local VS json file.
local_event_id() {
    local vs_path="${1/\///}"
    grep -oP '"eventId"\s*:\s*"\K[0-9]+' \
        "$WS_ROOT/release-info/versionSets/${vs_path}.json" 2>/dev/null || true
}

# Fetch the latest event ID for a version set from BMDS.
bmds_latest_event_id() {
    local response
    response=$(curl -s -L -b ~/.midway/cookie \
        "$BMDS/?Action=getVersionSetRevisionEventIds&versionSetName=$1&maxResults=1")
    if echo "$response" | grep -qi 'midway\|sign.in\|<html'; then
        echo "ERROR: Midway cookie is expired. Run 'mwinit' to refresh." >&2
        exit 1
    fi
    echo "$response" | grep -oP '<member>\K[0-9]+' || true
}

# Fetch branch name and commit for a package from BMDS.
# Outputs two lines: branch, then commit.
bmds_package_info() {
    local pkg="$1" mv="$2" vs="$3" eid="$4"
    local xml
    xml=$(curl -s -L -b ~/.midway/cookie \
        "$BMDS/?Action=getPackageVersionByVersionSet&packageName=${pkg}&majorVersion=${mv}&versionSet=${vs}${eid:+&eventId=${eid}}" 2>/dev/null) || true
    if echo "$xml" | grep -qi 'midway\|sign.in\|<html'; then
        echo "ERROR: Midway cookie is expired. Run 'mwinit' to refresh." >&2
        exit 1
    fi
    echo "$xml" | grep -oP '<branchName>\K[^<]+' || true
    echo "$xml" | grep -oP '<branchCLN>\K[^<]+'  || true
}

# Regenerate the bare VS file and .json from .pristine using Brazil's own parser.
# This is what `brazil ws sync --metadata` does internally (~90ms).
regen_vs_from_pristine() {
    local pristine="$1" bare="$2" json="$3"
    local ruby
    ruby=$(ls ~/.toolbox/tools/brazilcli/*/bin/ruby 2>/dev/null | sort -V | tail -1)
    [[ -z "$ruby" ]] && return 1
    "$ruby" -e '
require "amazon/brazil/package_config"
require "json"
data = Amazon::Brazil::PackageConfig.parse(File.read(ARGV[0]), :basic)
File.write(ARGV[1], Amazon::Brazil::PackageConfig.dump(data))
vs_key = data.keys.find { |k| k.start_with?("versionSet.") }
File.write(ARGV[2], JSON.fast_generate(data[vs_key]))
' "$pristine" "$bare" "$json" 2>/dev/null
}

# Update release-info VS files via direct BMDS curl (replaces brazil ws use --vs).
# ~1.2s vs ~5s for the brazil CLI equivalent.
update_vs_files_curl() {
    local ws_root="$1" vs="$2" eid="${3:-}"
    local vs_dir="${vs%%/*}" vs_name="${vs#*/}"
    local ri_dir="$ws_root/release-info/versionSets/$vs_dir"
    mkdir -p "$ri_dir"

    local eid_param=""
    [[ -n "$eid" ]] && eid_param="&eventId=$eid"

    local tmp_p tmp_g
    tmp_p=$(mktemp); tmp_g=$(mktemp)

    # Fetch pristine + graph in parallel
    curl -s -L -b ~/.midway/cookie \
        "$BMDS/?Action=getVersionSetFile&versionSetName=${vs}${eid_param}" \
        | grep -oP '<versionSetString>\K[^<]+' > "$tmp_p" &
    local pid_p=$!
    curl -s -L -b ~/.midway/cookie \
        "$BMDS/?Action=getVersionSetGraphFile&versionSetName=${vs}${eid_param}" \
        | grep -oP '<versionSetGraphString>\K[^<]+' > "$tmp_g" &
    local pid_g=$!
    wait "$pid_p" "$pid_g" 2>/dev/null || true

    if [[ -s "$tmp_p" ]]; then
        mv "$tmp_p" "$ri_dir/$vs_name.pristine"
        regen_vs_from_pristine "$ri_dir/$vs_name.pristine" "$ri_dir/$vs_name" "$ri_dir/$vs_name.json"
    else
        rm -f "$tmp_p"
    fi
    [[ -s "$tmp_g" ]] && mv "$tmp_g" "$ri_dir/$vs_name.graph" || rm -f "$tmp_g"
}

# Checkout a package to a specific branch and commit.
# Handles stash, rebase of local commits, and conflict reporting.
# When REBASE_ONLY=true, stays on the current branch and rebases onto the VS commit.
checkout_pkg() {
    local pkg_dir="$1" pkg_name="$2" mv="$3" branch="$4" commit="$5"
    local notes=""

    cd "$pkg_dir"

    local current_branch
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)

    # Save uncommitted work
    local stash_result had_stash=false
    stash_result=$(git stash push -u -m "auto-stash before vs-checkout $(date -Iseconds)" 2>&1)
    [[ "$stash_result" != *"No local changes"* ]] && had_stash=true && notes+="stashed"

    if [[ "${REBASE_ONLY:-}" == "true" && -n "$current_branch" && "$current_branch" != "$branch" ]]; then
        # Rebase current feature branch onto the VS commit
        local backup_branch="backup/${pkg_name}/$(date +%Y%m%d-%H%M%S)"
        git branch "$backup_branch" HEAD

        # Find the merge-base between current branch and the VS branch to identify local commits
        local base
        base=$(git merge-base "$current_branch" "origin/$branch" 2>/dev/null) || base="$commit"

        notes+="${notes:+, }rebased $current_branch onto ${commit:0:12}"

        if ! git rebase --onto "$commit" "$base" "$current_branch" --quiet 2>/dev/null; then
            echo "  ⚠  $pkg_name-$mv  $current_branch → ${commit:0:12}"
            echo "     REBASE CONFLICT — backup: $backup_branch"
            echo "     To resolve:  cd $pkg_dir && git add <files> && git rebase --continue"
            echo "     To abort:    git rebase --abort && git reset --hard $backup_branch"
            $had_stash && echo "     ⚠ Stashed changes pending — run 'git stash pop' after resolving"
            return 1
        fi
    else
        # Normal mode: switch to VS branch
        git checkout "$branch" --quiet 2>/dev/null \
            || git checkout -b "$branch" "origin/$branch" --quiet 2>/dev/null || true

        # Rebase local commits or reset
        local unpushed
        unpushed=$(git log "$commit..HEAD" --oneline 2>/dev/null) || true

        if [[ -n "$unpushed" ]]; then
            local backup_branch="backup/${pkg_name}/$(date +%Y%m%d-%H%M%S)"
            git branch "$backup_branch" HEAD
            [[ -n "$notes" ]] && notes+=", "
            notes+="rebased"

            if ! git rebase --onto "$commit" "origin/$branch" "$branch" --quiet 2>/dev/null; then
                echo "  ⚠  $pkg_name-$mv  $branch @ ${commit:0:12}"
                echo "     REBASE CONFLICT — backup: $backup_branch"
                echo "     To resolve:  cd $pkg_dir && git add <files> && git rebase --continue"
                echo "     To abort:    git rebase --abort && git reset --hard $commit"
                $had_stash && echo "     ⚠ Stashed changes pending — run 'git stash pop' after resolving"
                return 1
            fi
        else
            git reset --hard "$commit" >/dev/null 2>&1
        fi
    fi

    # Restore stash
    if $had_stash; then
        if git stash pop 2>/dev/null; then
            notes+=", restored"
        else
            local label="$branch @ ${commit:0:12}"
            [[ "${REBASE_ONLY:-}" == "true" && "$current_branch" != "$branch" ]] && label="$current_branch → ${commit:0:12}"
            echo "  ⚠  $pkg_name-$mv  $label  — stash conflict"
            echo "     Resolve then run: git stash drop"
            return 1
        fi
    fi

    local label="$branch @ ${commit:0:12}"
    [[ "${REBASE_ONLY:-}" == "true" && -n "$current_branch" && "$current_branch" != "$branch" ]] && label="$current_branch → ${commit:0:12}"
    local suffix=""
    [[ -n "$notes" ]] && suffix="  ($notes)"
    echo "  ✓  $pkg_name-$mv  $label$suffix"
}
export -f checkout_pkg

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────────────────

REBASE_ONLY=false

if [[ $# -ge 1 ]]; then
    [[ "$1" == "--rebase-only" ]] && { REBASE_ONLY=true; shift; }
    if [[ $# -ge 1 ]]; then
        if [[ "$1" == *@* ]]; then
            VS="${1%%@*}"; EVENT_ID="${1#*@}"
        else
            VS="$1"; EVENT_ID="${2:-}"
        fi
    else
        VS=""; EVENT_ID=""
    fi
else
    VS=""; EVENT_ID=""
fi

export REBASE_ONLY

# ─────────────────────────────────────────────────────────────────────────────
# Resolve workspace, version set, and event ID
# ─────────────────────────────────────────────────────────────────────────────

# Validate Midway cookie exists
if [[ ! -f ~/.midway/cookie ]]; then
    echo "ERROR: Midway cookie not found. Run 'mwinit' to refresh." >&2
    exit 1
fi

WS_ROOT=$(find_workspace_root) || { echo "ERROR: Not inside a Brazil workspace." >&2; exit 1; }

if [[ -z "$VS" ]]; then
    VS=$(awk -F'"' '/versionSet\s*=/ {print $2}' "$WS_ROOT/packageInfo")
    VS="${VS%%@*}"
    [[ -z "$VS" ]] && { echo "ERROR: Could not determine current version set." >&2; exit 1; }
fi

current_eid=$(local_event_id "$VS")

if [[ -z "$EVENT_ID" ]]; then
    # Need event ID for VS file update — fetch it now (overlaps with per-package work below)
    eid_tmpfile=$(mktemp)
    ( bmds_latest_event_id "$VS" > "$eid_tmpfile" ) &
    eid_pid=$!
else
    eid_pid=""
fi

echo "Workspace: $WS_ROOT"
echo "Version set: $VS${EVENT_ID:+@$EVENT_ID}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Update workspace VS files in background (curl-based, ~1.2s vs ~5s brazil CLI)
# Waits for eid resolution if needed, then fetches VS files.
# ─────────────────────────────────────────────────────────────────────────────

(
    if [[ -n "${eid_pid:-}" ]]; then
        wait "$eid_pid" 2>/dev/null || true
        EVENT_ID=$(cat "$eid_tmpfile" 2>/dev/null || true)
        rm -f "$eid_tmpfile"
    fi
    update_vs_files_curl "$WS_ROOT" "$VS" "$EVENT_ID"
) &
ws_pid=$!

# ─────────────────────────────────────────────────────────────────────────────
# Process each package in parallel:
#   1. git fetch origin      (background — overlaps with BMDS call)
#   2. BMDS package lookup   (get branch + commit)
#   3. checkout_pkg           (after fetch completes)
# ─────────────────────────────────────────────────────────────────────────────

tmpdir=$(mktemp -d)
pids=()
names=()

for pkg_dir in "$WS_ROOT"/src/*/; do
    pkg_name=$(basename "$pkg_dir")
    [[ ! -e "$pkg_dir/.git" ]] && continue

    mv=$(grep -zoP 'packages\s*=\s*\{[^}]*' "$WS_ROOT/packageInfo" 2>/dev/null | grep -oP "${pkg_name}-\K[^\s=;]+" | head -1)
    [[ -z "$mv" ]] && { echo "  ·  $pkg_name  (not in packageInfo)"; continue; }

    echo "  …  $pkg_name-$mv"

    (
        ( cd "$pkg_dir" && git fetch origin --quiet 2>/dev/null ) &
        fetch_pid=$!

        readarray -t info < <(bmds_package_info "$pkg_name" "$mv" "$VS" "$EVENT_ID")
        branch="${info[0]:-}"; commit="${info[1]:-}"

        wait "$fetch_pid" 2>/dev/null || true

        if [[ -z "$branch" || -z "$commit" ]]; then
            echo "  ·  $pkg_name-$mv  (not in version set)"
            exit 0
        fi

        checkout_pkg "$pkg_dir" "$pkg_name" "$mv" "$branch" "$commit"
    ) > "$tmpdir/$pkg_name" 2>&1 &
    pids+=("$!")
    names+=("$pkg_name")
done

# ─────────────────────────────────────────────────────────────────────────────
# Collect results
# ─────────────────────────────────────────────────────────────────────────────

failures=0
while [[ ${#pids[@]} -gt 0 ]]; do
    for j in "${!pids[@]}"; do
        if ! kill -0 "${pids[$j]}" 2>/dev/null; then
            wait "${pids[$j]}" || failures=$((failures + 1))
            cat "$tmpdir/${names[$j]}"
            unset 'pids[j]' 'names[j]'
            break
        fi
    done
done
rm -rf "$tmpdir"

if [[ -n "$ws_pid" ]]; then
    wait "$ws_pid" || { echo "  ⚠  VS file update failed"; failures=$((failures + 1)); }
fi

echo ""
if [[ $failures -gt 0 ]]; then
    echo "Done with $failures failure(s)."
    exit 1
else
    echo "Done."
fi
