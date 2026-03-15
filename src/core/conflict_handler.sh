#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Conflict Handler — preserves both sides of diverged-history conflicts
#
# When se_pull returns 1 (branches diverged, fast-forward not possible),
# this module preserves the local device's version alongside the remote
# (canonical) version, writes structured metadata, and provides resolution
# functions to clean up conflict artifacts.
#
# Prerequisites:
#   - PAL loaded and validated (provides CONTINUITY_GIT_BIN, CONTINUITY_DEVICE_NAME,
#     pal_log(), pal_is_online())
#   - src/core/sync_engine.sh sourced and initialized (se_stage_files, se_push,
#     se_get_head_commit)
#   - src/core/cold_start.sh sourced (cs_store_commit)
#
# Public functions: ch_handle_pull_conflict, ch_preserve_conflict,
#                   ch_list_conflicts, ch_list_local_files,
#                   ch_resolve, ch_resolve_all

# ch_preserve_conflict — preserve local version of a conflicted save
# Usage: ch_preserve_conflict <repo_dir> <repo_path> <device_name>
# Creates <repo_path>.<device_name>.local and <repo_path>.conflict
# Does NOT commit — caller batches and commits.
# Returns: 0 on success, 1 on error
ch_preserve_conflict() {
    local repo_dir repo_path device_name
    repo_dir="$1"
    repo_path="$2"
    device_name="$3"

    local local_file conflict_meta
    local_file="$repo_dir/$repo_path.$device_name.local"
    conflict_meta="$repo_dir/$repo_path.conflict"

    # Copy local .srm bytes to .local file
    if ! cp "$repo_dir/$repo_path" "$local_file"; then
        pal_log "error" "ch_preserve_conflict: cp failed for $repo_path"
        return 1
    fi

    # Derive remote device and timestamp from git log on origin/main
    local remote_info remote_timestamp remote_device
    remote_info=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" \
        log -1 --format="%cI%n%B" origin/main -- "$repo_path" 2>/dev/null) || true

    remote_timestamp=$(printf '%s\n' "$remote_info" | head -1)
    remote_device=$(printf '%s\n' "$remote_info" | grep '^device:' | head -1 | sed 's/^device: *//')
    [ -z "$remote_device" ] && remote_device="unknown"

    # Local timestamp — use current UTC time (BusyBox date cannot convert epoch)
    local local_timestamp
    local_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || local_timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

    # Escape double quotes in values
    local esc_file esc_remote_device esc_device_name
    esc_file=$(printf '%s' "$repo_path" | sed 's/"/\\"/g')
    esc_remote_device=$(printf '%s' "$remote_device" | sed 's/"/\\"/g')
    esc_device_name=$(printf '%s' "$device_name" | sed 's/"/\\"/g')

    # Write .conflict JSON
    if ! printf '{\n  "_schema_version": "1.0",\n  "file": "%s",\n  "remote_device": "%s",\n  "remote_timestamp": "%s",\n  "local_device": "%s",\n  "local_timestamp": "%s",\n  "status": "unresolved"\n}\n' \
        "$esc_file" "$esc_remote_device" "$remote_timestamp" "$esc_device_name" "$local_timestamp" \
        > "$conflict_meta"; then
        pal_log "error" "ch_preserve_conflict: write failed for $conflict_meta"
        return 1
    fi

    return 0
}

# ch_handle_pull_conflict — handle a diverged pull by preserving conflicts
# Usage: ch_handle_pull_conflict <repo_dir>
# Called when se_pull returns 1 (diverged). Fetches remote, identifies
# conflicted .srm files, preserves local versions, accepts remote as
# canonical, commits conflict artifacts, pushes, and calls pal_on_conflict.
# Returns: 0 on success, 1 on error
ch_handle_pull_conflict() {
    local repo_dir
    repo_dir="$1"

    # Step 1: Fetch remote
    if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" fetch origin 2>/dev/null; then
        pal_log "error" "Conflict handler: fetch failed"
        return 1
    fi

    # Step 2: Identify conflicted .srm files
    local conflicted
    conflicted=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" \
        diff --name-only HEAD origin/main -- '*.srm' 2>/dev/null) || true

    if [ -z "$conflicted" ]; then
        # No .srm conflicts — accept remote
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" reset --hard origin/main >/dev/null 2>&1
        pal_log "info" "Conflict handler: no .srm conflicts — reset to remote"
        return 0
    fi

    # Step 3: Preserve each conflicted file
    printf '%s\n' "$conflicted" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        if ! ch_preserve_conflict "$repo_dir" "$repo_path" "$CONTINUITY_DEVICE_NAME"; then
            pal_log "error" "Failed to preserve $repo_path"
            return 1
        fi
    done || return 1

    # Step 4: Accept remote as canonical
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" reset --hard origin/main >/dev/null 2>&1

    # Step 5: Stage all conflict artifacts
    local stage_list _ch_tmpfile
    _ch_tmpfile=$(mktemp)
    printf '' > "$_ch_tmpfile"
    printf '%s\n' "$conflicted" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        printf '%s\n%s\n' "$repo_path.$CONTINUITY_DEVICE_NAME.local" "$repo_path.conflict" \
            >> "$_ch_tmpfile"
    done
    stage_list=$(cat "$_ch_tmpfile")
    rm -f "$_ch_tmpfile"

    if ! se_stage_files "$repo_dir" "$stage_list"; then
        pal_log "error" "Conflict handler: staging failed"
        return 1
    fi

    # Step 6: Commit conflict artifacts
    local conflict_count
    conflict_count=$(printf '%s\n' "$conflicted" | grep -c '.')
    if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
        -m "conflict: $conflict_count save(s) preserved from $CONTINUITY_DEVICE_NAME" 2>/dev/null; then
        pal_log "error" "Conflict handler: commit failed"
        return 1
    fi

    # Step 7: Push
    local push_rc
    push_rc=0
    se_push "$repo_dir" || push_rc=$?
    if [ "$push_rc" -eq 1 ]; then
        pal_log "error" "Conflict handler: push failed"
        return 1
    elif [ "$push_rc" -eq 2 ]; then
        pal_log "warn" "Conflict artifacts committed locally — push pending"
    fi

    # Step 8: Update last_known_commit
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    cs_store_commit "$repo_dir" "$head_hash"

    # Step 9: Call pal_on_conflict hook for each conflicted file
    printf '%s\n' "$conflicted" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        if command -v pal_on_conflict >/dev/null 2>&1; then
            pal_on_conflict "$repo_path"
        fi
    done

    # Step 10: Done
    pal_log "info" "Conflict handler: $conflict_count conflict(s) preserved"
    return 0
}

# ch_list_conflicts — enumerate all unresolved conflict metadata files
# Usage: ch_list_conflicts <repo_dir>
# Prints repo-relative paths of .conflict files, one per line.
# Returns: 0 always
ch_list_conflicts() {
    local repo_dir
    repo_dir="$1"
    find "$repo_dir" \
        ! -path "*/.git/*" \
        -name "*.conflict" \
        2>/dev/null \
    | sed "s|^$repo_dir/||"
    return 0
}

# ch_list_local_files — enumerate all .local files with device attribution
# Usage: ch_list_local_files <repo_dir>
# Prints "<canonical_repo_path> <device_name>" per line.
# Returns: 0 always
ch_list_local_files() {
    local repo_dir
    repo_dir="$1"
    find "$repo_dir" \
        ! -path "*/.git/*" \
        -name "*.local" \
        2>/dev/null \
    | sed "s|^$repo_dir/||" \
    | while IFS= read -r local_path; do
        local base device
        base=$(printf '%s' "$local_path" | sed 's/\.[^.]*\.local$//')
        device=$(printf '%s' "$local_path" | sed 's/.*\.srm\.\([^.]*\)\.local$/\1/')
        printf '%s %s\n' "$base" "$device"
    done
    return 0
}

# ch_resolve — resolve a single conflict
# Usage: ch_resolve <repo_dir> <repo_path> <resolution>
# resolution: keep_remote, keep_local, keep_newest, prompt
# Returns: 0 on success, 1 on error
ch_resolve() {
    local repo_dir repo_path resolution
    repo_dir="$1"
    repo_path="$2"
    resolution="$3"

    # Find .local file(s) for this save
    local srm_basename srm_dir local_files local_file
    srm_basename=$(basename "$repo_path")
    srm_dir=$(dirname "$repo_path")
    local_files=$(find "$repo_dir/$srm_dir" \
        -name "$srm_basename.*.local" \
        ! -path "*/.git/*" \
        2>/dev/null)

    if [ -z "$local_files" ]; then
        pal_log "warn" "ch_resolve: no .local file for $repo_path"
        return 1
    fi

    local conflict_meta
    conflict_meta="$repo_dir/$repo_path.conflict"
    if [ ! -f "$conflict_meta" ]; then
        pal_log "warn" "ch_resolve: no .conflict metadata for $repo_path"
        return 1
    fi

    case "$resolution" in
        keep_remote)
            # Remote is already canonical — remove artifacts
            printf '%s\n' "$local_files" | while IFS= read -r lf; do
                [ -z "$lf" ] && continue
                local lf_rel
                lf_rel=$(printf '%s' "$lf" | sed "s|^$repo_dir/||")
                rm -f "$lf"
                "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$lf_rel" >/dev/null 2>&1 || true
            done
            rm -f "$conflict_meta"
            "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$repo_path.conflict" >/dev/null 2>&1 || true
            if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
                -m "resolve: keep remote $repo_path" >/dev/null 2>&1; then
                pal_log "error" "ch_resolve: commit failed for keep_remote $repo_path"
                return 1
            fi
            ;;

        keep_local)
            # Copy first .local over canonical
            local_file=$(printf '%s\n' "$local_files" | head -1)
            if ! cp "$local_file" "$repo_dir/$repo_path"; then
                pal_log "error" "ch_resolve: cp failed for keep_local $repo_path"
                return 1
            fi
            "$CONTINUITY_GIT_BIN" -C "$repo_dir" add "$repo_path" 2>/dev/null
            # Remove all .local files
            printf '%s\n' "$local_files" | while IFS= read -r lf; do
                [ -z "$lf" ] && continue
                local lf_rel
                lf_rel=$(printf '%s' "$lf" | sed "s|^$repo_dir/||")
                rm -f "$lf"
                "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$lf_rel" >/dev/null 2>&1 || true
            done
            rm -f "$conflict_meta"
            "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$repo_path.conflict" >/dev/null 2>&1 || true
            if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
                -m "resolve: keep local $repo_path" >/dev/null 2>&1; then
                pal_log "error" "ch_resolve: commit failed for keep_local $repo_path"
                return 1
            fi
            ;;

        keep_newest)
            # Compare timestamps from .conflict metadata
            local remote_ts local_ts
            remote_ts=$(grep '"remote_timestamp"' "$conflict_meta" | sed 's/.*: *"\([^"]*\)".*/\1/')
            local_ts=$(grep '"local_timestamp"' "$conflict_meta" | sed 's/.*: *"\([^"]*\)".*/\1/')
            if [ "$local_ts" \> "$remote_ts" ]; then
                ch_resolve "$repo_dir" "$repo_path" "keep_local"
            else
                ch_resolve "$repo_dir" "$repo_path" "keep_remote"
            fi
            return $?
            ;;

        prompt)
            # Do nothing — leave artifacts for platform UI
            pal_log "info" "ch_resolve: $repo_path left unresolved (prompt mode)"
            return 0
            ;;

        *)
            pal_log "error" "ch_resolve: unknown resolution '$resolution'"
            return 1
            ;;
    esac

    # Post-resolution: update last_known_commit and push (keep_remote/keep_local only)
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    cs_store_commit "$repo_dir" "$head_hash"

    if pal_is_online; then
        local push_rc
        push_rc=0
        se_push "$repo_dir" || push_rc=$?
        if [ "$push_rc" -eq 1 ]; then
            pal_log "warn" "ch_resolve: push failed after resolving $repo_path"
        fi
    fi

    return 0
}

# ch_resolve_all — resolve all conflicts with a given resolution
# Usage: ch_resolve_all <repo_dir> <resolution>
# Returns: 0 if all resolved, 1 if any failed
ch_resolve_all() {
    local repo_dir resolution
    repo_dir="$1"
    resolution="$2"

    local conflicts
    conflicts=$(ch_list_conflicts "$repo_dir")
    [ -z "$conflicts" ] && return 0

    local fail_file
    fail_file=$(mktemp)
    printf '' > "$fail_file"

    printf '%s\n' "$conflicts" | while IFS= read -r conflict_path; do
        [ -z "$conflict_path" ] && continue
        local repo_path
        repo_path=$(printf '%s' "$conflict_path" | sed 's/\.conflict$//')
        if ! ch_resolve "$repo_dir" "$repo_path" "$resolution"; then
            printf 'fail' > "$fail_file"
        fi
    done

    local had_failure
    had_failure=$(cat "$fail_file")
    rm -f "$fail_file"
    [ -n "$had_failure" ] && return 1
    return 0
}
