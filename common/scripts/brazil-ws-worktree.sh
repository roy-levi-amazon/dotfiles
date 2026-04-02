#!/bin/bash
set -euo pipefail

BMDS="https://brazil-metadata-sso.corp.amazon.com"
COOKIE=~/.midway/cookie
PROJECTS_DIR=~/projects

# ─────────────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
    create <branch> [--packages pkg1,pkg2,...] [--vs VS] [--path DIR]
        Create a new workspace worktree with packages checked out at the VS tip.
        Defaults: all packages from source workspace, same VS, ~/projects/<ws>-wt-<branch>

    list
        List active worktrees for packages in the current workspace.

    remove <branch>
        Remove a worktree and clean up.

Examples:
    $(basename "$0") create my-feature
    $(basename "$0") create my-feature --packages EbsServerTest,EbsServer
    $(basename "$0") create my-feature --vs EBSServer/mainline
    $(basename "$0") list
    $(basename "$0") remove my-feature
EOF
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

find_workspace_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        [[ -f "$dir/packageInfo" ]] && echo "$dir" && return
        dir=$(dirname "$dir")
    done
    echo "ERROR: Not inside a Brazil workspace." >&2
    return 1
}

parse_vs_from_packageinfo() {
    awk -F'"' '/versionSet\s*=/ {print $2}' "$1"
}

parse_packages_from_packageinfo() {
    # Extracts "PkgName-1.0" entries, outputs "PkgName 1.0" per line
    grep -oP '[A-Za-z][\w-]+-[\d.]+(?=\s*=\s*\.)' "$1" | sed 's/-\([0-9]\)/ \1/'
}

parse_platform_from_packageinfo() {
    grep -oP 'platformOverride\s*=\s*\K[^;]+' "$1" || true
}

bmds_latest_event_id() {
    curl -s -L -b "$COOKIE" \
        "$BMDS/?Action=getVersionSetRevisionEventIds&versionSetName=$1&maxResults=1" \
        | grep -oP '<member>\K[0-9]+' || true
}

bmds_vs_file() {
    curl -s -L -b "$COOKIE" \
        "$BMDS/?Action=getVersionSetFile&versionSetName=$1${2:+&eventId=$2}" \
        | grep -oP '<versionSetString>\K[^<]+'
}

bmds_graph_file() {
    curl -s -L -b "$COOKIE" \
        "$BMDS/?Action=getVersionSetGraphFile&versionSetName=$1${2:+&eventId=$2}" \
        | grep -oP '<versionSetGraphString>\K[^<]+'
}

bmds_package_info() {
    local pkg="$1" mv="$2" vs="$3" eid="$4"
    local xml
    xml=$(curl -s -L -b "$COOKIE" \
        "$BMDS/?Action=getPackageVersionByVersionSet&packageName=${pkg}&majorVersion=${mv}&versionSet=${vs}${eid:+&eventId=${eid}}" 2>/dev/null) || true
    echo "$xml" | grep -oP '<branchName>\K[^<]+' || true
    echo "$xml" | grep -oP '<branchCLN>\K[^<]+'  || true
}

# ─────────────────────────────────────────────────────────────────────────────
# create
# ─────────────────────────────────────────────────────────────────────────────

cmd_create() {
    local branch="" packages_filter="" vs="" dest=""

    # Parse args
    [[ $# -lt 1 ]] && usage
    branch="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --packages) packages_filter="$2"; shift 2 ;;
            --vs)       vs="$2"; shift 2 ;;
            --path)     dest="$2"; shift 2 ;;
            *)          echo "Unknown option: $1" >&2; usage ;;
        esac
    done

    # Resolve source workspace
    local src_ws
    src_ws=$(find_workspace_root)
    local src_ws_name
    src_ws_name=$(basename "$src_ws")

    [[ -z "$vs" ]] && vs=$(parse_vs_from_packageinfo "$src_ws/packageInfo")
    [[ -z "$dest" ]] && dest="$PROJECTS_DIR/${src_ws_name}-wt-${branch}"

    if [[ -d "$dest" ]]; then
        echo "ERROR: $dest already exists." >&2
        exit 1
    fi

    # Parse VS path for directory structure (EBSServer/mainline → EBSServer + mainline)
    local vs_dir="${vs%%/*}"
    local vs_name="${vs#*/}"

    echo "Source workspace: $src_ws"
    echo "Version set:      $vs"
    echo "Worktree branch:  $branch"
    echo "Destination:      $dest"
    echo ""

    # ── Collect packages ──────────────────────────────────────────────────
    local -a pkg_names=() pkg_versions=()
    while IFS=' ' read -r name ver; do
        if [[ -n "$packages_filter" ]]; then
            echo ",$packages_filter," | grep -q ",$name," || continue
        fi
        pkg_names+=("$name")
        pkg_versions+=("$ver")
    done < <(parse_packages_from_packageinfo "$src_ws/packageInfo")

    if [[ ${#pkg_names[@]} -eq 0 ]]; then
        echo "ERROR: No packages matched." >&2
        exit 1
    fi

    echo "Packages: ${pkg_names[*]}"
    echo ""

    # ── Create workspace skeleton ─────────────────────────────────────────
    mkdir -p "$dest/release-info/versionSets/$vs_dir" "$dest/src"

    # ── Fire all network requests in parallel ─────────────────────────────
    local tmpdir
    tmpdir=$(mktemp -d)

    # 1) VS file + graph file (parallel)
    (bmds_vs_file "$vs" "" > "$tmpdir/vs_pristine" 2>/dev/null) &
    local pid_vs=$!

    (bmds_graph_file "$vs" "" > "$tmpdir/vs_graph" 2>/dev/null) &
    local pid_graph=$!

    # 2) Per-package: git fetch + BMDS lookup (parallel)
    local -a pkg_pids=()
    for i in "${!pkg_names[@]}"; do
        local name="${pkg_names[$i]}" ver="${pkg_versions[$i]}"
        local src_git="$src_ws/src/$name"
        (
            # git fetch in background
            ( cd "$src_git" && git fetch origin --quiet 2>/dev/null ) &
            local fetch_pid=$!

            # BMDS lookup
            readarray -t info < <(bmds_package_info "$name" "$ver" "$vs" "")
            local pkg_branch="${info[0]:-}" pkg_commit="${info[1]:-}"

            wait "$fetch_pid" 2>/dev/null || true

            echo "$pkg_branch" > "$tmpdir/pkg_${name}_branch"
            echo "$pkg_commit" > "$tmpdir/pkg_${name}_commit"
        ) &
        pkg_pids+=($!)
    done

    # ── Write packageInfo while network is in flight ──────────────────────
    local platform
    platform=$(parse_platform_from_packageinfo "$src_ws/packageInfo")

    {
        echo 'base = {'
        echo "  workspace = $(whoami)_$(basename "$dest");"
        echo "  versionSet = \"$vs\";"
        echo '  dependencyModel = brazil;'
        echo '};'
        echo -n 'packages = { '
        for i in "${!pkg_names[@]}"; do
            echo -n "${pkg_names[$i]}-${pkg_versions[$i]} = .; "
        done
        echo '};'
        [[ -n "$platform" ]] && echo "platformOverride = $platform;"
    } > "$dest/packageInfo"

    # ── Wait for VS files ─────────────────────────────────────────────────
    wait "$pid_vs" 2>/dev/null || true
    wait "$pid_graph" 2>/dev/null || true

    local pristine_content
    pristine_content=$(cat "$tmpdir/vs_pristine")
    if [[ -n "$pristine_content" ]]; then
        echo "$pristine_content" > "$dest/release-info/versionSets/$vs_dir/$vs_name.pristine"
        echo "  ✓  Version set fetched"
    else
        echo "  ⚠  Failed to fetch VS file, copying from source workspace"
        cp "$src_ws/release-info/versionSets/$vs_dir/$vs_name.pristine" \
           "$dest/release-info/versionSets/$vs_dir/$vs_name.pristine" 2>/dev/null || true
    fi

    local graph_content
    graph_content=$(cat "$tmpdir/vs_graph")
    if [[ -n "$graph_content" ]]; then
        echo "$graph_content" > "$dest/release-info/versionSets/$vs_dir/$vs_name.graph"
    fi

    # ── Wait for all package lookups ──────────────────────────────────────
    local failures=0
    for pid in "${pkg_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # ── Create worktrees ──────────────────────────────────────────────────
    for i in "${!pkg_names[@]}"; do
        local name="${pkg_names[$i]}"
        local src_git="$src_ws/src/$name"
        local pkg_branch pkg_commit

        pkg_branch=$(cat "$tmpdir/pkg_${name}_branch" 2>/dev/null || true)
        pkg_commit=$(cat "$tmpdir/pkg_${name}_commit" 2>/dev/null || true)

        if [[ -z "$pkg_branch" || -z "$pkg_commit" ]]; then
            echo "  ⚠  $name  (not in version set, skipping)"
            failures=$((failures + 1))
            continue
        fi

        # Create worktree at the VS commit, on a new branch
        if git -C "$src_git" worktree add -b "$branch" "$dest/src/$name" "$pkg_commit" 2>/dev/null; then
            echo "  ✓  $name  $pkg_branch @ ${pkg_commit:0:12}"
        elif git -C "$src_git" worktree add "$dest/src/$name" "$pkg_commit" 2>/dev/null; then
            # Branch already exists — detached HEAD at commit, then checkout branch
            ( cd "$dest/src/$name" && git checkout -B "$branch" 2>/dev/null ) || true
            echo "  ✓  $name  $pkg_branch @ ${pkg_commit:0:12} (branch existed)"
        else
            echo "  ✗  $name  failed to create worktree"
            failures=$((failures + 1))
        fi
    done

    rm -rf "$tmpdir"

    echo ""
    if [[ $failures -gt 0 ]]; then
        echo "Done with $failures issue(s)."
        echo "cd $dest"
        exit 1
    else
        echo "Done. Workspace ready at:"
        echo "  cd $dest"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# list
# ─────────────────────────────────────────────────────────────────────────────

cmd_list() {
    local src_ws
    src_ws=$(find_workspace_root)

    echo "Worktrees for packages in $(basename "$src_ws"):"
    echo ""
    for pkg_dir in "$src_ws"/src/*/; do
        [[ ! -d "$pkg_dir/.git" && ! -f "$pkg_dir/.git" ]] && continue
        local name
        name=$(basename "$pkg_dir")
        local wt_output
        wt_output=$(git -C "$pkg_dir" worktree list 2>/dev/null | grep -v "^$pkg_dir" || true)
        if [[ -n "$wt_output" ]]; then
            echo "  $name:"
            echo "$wt_output" | sed 's/^/    /'
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# remove
# ─────────────────────────────────────────────────────────────────────────────

cmd_remove() {
    [[ $# -lt 1 ]] && usage
    local branch="$1"

    local src_ws
    src_ws=$(find_workspace_root)
    local src_ws_name
    src_ws_name=$(basename "$src_ws")
    local dest="$PROJECTS_DIR/${src_ws_name}-wt-${branch}"

    if [[ ! -d "$dest" ]]; then
        echo "ERROR: $dest does not exist." >&2
        exit 1
    fi

    echo "Removing worktree workspace: $dest"

    for pkg_dir in "$dest"/src/*/; do
        [[ ! -d "$pkg_dir" ]] && continue
        local name
        name=$(basename "$pkg_dir")
        local src_git="$src_ws/src/$name"

        if [[ -d "$src_git" ]]; then
            git -C "$src_git" worktree remove --force "$pkg_dir" 2>/dev/null && \
                echo "  ✓  $name worktree removed" || \
                echo "  ⚠  $name worktree remove failed (cleaning up manually)"
        fi
    done

    rm -rf "$dest"
    echo ""
    echo "Done. $dest removed."
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

[[ $# -lt 1 ]] && usage

cmd="$1"; shift
case "$cmd" in
    create) cmd_create "$@" ;;
    list)   cmd_list ;;
    remove) cmd_remove "$@" ;;
    *)      usage ;;
esac
