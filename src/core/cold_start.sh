#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Cold Start — first bidirectional sync after enrollment
# Merges device saves with repo saves, resolves conflicts (repo wins),
# creates sentinel and commit hash for subsequent incremental syncs.
# Requires PAL, path mapper, sync engine, and change detector to be loaded.

# cs_is_cold_start — check if cold start is needed
# Usage: cs_is_cold_start <repo_dir>
# Returns: 0 if cold start needed (no sentinel), 1 if sentinel present
cs_is_cold_start() {
    local repo_dir
    repo_dir="$1"
    [ ! -f "$repo_dir/.continuity/sentinel" ]
}

# cs_store_commit — write commit hash to last_known_commit
# Usage: cs_store_commit <repo_dir> <commit_hash>
# Returns: 0 on success, 1 on error
cs_store_commit() {
    local repo_dir commit_hash
    repo_dir="$1"
    commit_hash="$2"
    mkdir -p "$repo_dir/.continuity"
    printf '%s\n' "$commit_hash" > "$repo_dir/.continuity/last_known_commit"
}

# cs_read_commit — read stored commit hash
# Usage: cs_read_commit <repo_dir>
# Prints commit hash to stdout. Returns: 0 on success, 1 if not found/empty
cs_read_commit() {
    local repo_dir commit_file hash
    repo_dir="$1"
    commit_file="$repo_dir/.continuity/last_known_commit"
    [ -f "$commit_file" ] || return 1
    hash=$(cat "$commit_file")
    hash=$(printf '%s' "$hash" | tr -d '[:space:]')
    [ -n "$hash" ] || return 1
    printf '%s' "$hash"
    return 0
}

# cs_create_sentinel — create sentinel file with timestamp
# Usage: cs_create_sentinel <repo_dir>
# Returns: 0 on success, 1 on error
cs_create_sentinel() {
    local repo_dir
    repo_dir="$1"
    mkdir -p "$repo_dir/.continuity"
    date '+%Y-%m-%dT%H:%M:%S' > "$repo_dir/.continuity/sentinel"
}

# cs_run — execute the full cold start sync flow
# Usage: cs_run <repo_dir>
# Returns: 0 on success, 1 on error
cs_run() {
    local repo_dir was_offline pull_rc
    repo_dir="$1"
    was_offline=""

    # Step 1: Pull latest from remote
    if pal_is_online; then
        pull_rc=0
        se_pull "$repo_dir" || pull_rc=$?
        if [ "$pull_rc" -eq 1 ]; then
            pal_log "error" "Cold start: pull failed (diverged)"
            return 1
        elif [ "$pull_rc" -eq 2 ]; then
            pal_log "warn" "Cold start: pull network error — working with local clone only"
            was_offline=true
        fi
    else
        pal_log "warn" "Cold start: offline — working with local clone only"
        was_offline=true
    fi

    # Step 2: Enumerate repo saves
    local repo_saves
    repo_saves=$(cd_list_repo_saves "$repo_dir")

    # Step 3: Enumerate device saves
    local device_saves
    device_saves=$(cd_list_device_saves)

    # Temp file for conflict artifact paths (subshell-safe accumulation)
    local conflict_tmp
    conflict_tmp=$(mktemp)
    printf '' > "$conflict_tmp"

    # Step 4: For each repo save, sync to device
    if [ -n "$repo_saves" ]; then
        printf '%s\n' "$repo_saves" | while IFS= read -r repo_path; do
            [ -z "$repo_path" ] && continue

            local local_path
            local_path=$(pm_repo_to_local "$repo_path" 2>/dev/null)
            if [ $? -ne 0 ] || [ -z "$local_path" ]; then
                pal_log "warn" "Cold start: unknown system in repo path: $repo_path"
                continue
            fi

            local repo_file
            repo_file="$repo_dir/$repo_path"

            if [ ! -f "$local_path" ]; then
                # Repo-only: copy to device
                mkdir -p "$(dirname "$local_path")"
                cp "$repo_file" "$local_path"
                pal_log "info" "Cold start: pulled $repo_path to device"
            elif ! cmp -s "$repo_file" "$local_path"; then
                # Conflict: repo wins, preserve device version
                local conflict_name
                conflict_name="$repo_path.$CONTINUITY_DEVICE_NAME.local"
                cp "$local_path" "$repo_dir/$conflict_name"
                cp "$repo_file" "$local_path"

                # Write .conflict metadata
                local timestamp
                timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
                printf '{\n  "canonical": "%s",\n  "local_device": "%s",\n  "timestamp": "%s",\n  "source": "cold_start"\n}\n' \
                    "$repo_path" "$CONTINUITY_DEVICE_NAME" "$timestamp" > "$repo_dir/$repo_path.conflict"

                # Accumulate conflict artifact paths
                printf '%s\n%s\n' "$conflict_name" "$repo_path.conflict" >> "$conflict_tmp"

                pal_log "warn" "Cold start: conflict on $repo_path — device version preserved as $conflict_name"

                # Optional hook
                if command -v pal_on_conflict >/dev/null 2>&1; then
                    pal_on_conflict "$repo_path"
                fi
            fi
            # Else: identical — no-op
        done
    fi

    # Step 5: For each device save, sync to repo
    if [ -n "$device_saves" ]; then
        printf '%s\n' "$device_saves" | while IFS= read -r local_path; do
            [ -z "$local_path" ] && continue

            local repo_path
            repo_path=$(pm_local_to_repo "$local_path" 2>/dev/null)
            if [ $? -ne 0 ] || [ -z "$repo_path" ]; then
                pal_log "warn" "Cold start: unknown system dir for device path: $local_path"
                continue
            fi

            local repo_file
            repo_file="$repo_dir/$repo_path"

            if [ ! -f "$repo_file" ]; then
                # Device-only: copy to repo
                mkdir -p "$(dirname "$repo_file")"
                cp "$local_path" "$repo_file"
                pal_log "info" "Cold start: pushed $repo_path from device"
            fi
            # Else: already handled in step 4
        done
    fi

    # Step 6: Detect and stage all changes
    local changed conflict_files
    changed=$(cd_detect_changes "$repo_dir")
    conflict_files=$(cat "$conflict_tmp")
    rm -f "$conflict_tmp"

    if [ -n "$conflict_files" ]; then
        if [ -n "$changed" ]; then
            changed="$changed
$conflict_files"
        else
            changed="$conflict_files"
        fi
    fi

    # Step 7: Commit and push if changes exist
    if [ -n "$changed" ]; then
        if ! se_stage_files "$repo_dir" "$changed"; then
            pal_log "error" "Cold start: failed to stage files"
            return 1
        fi

        if ! se_commit "$repo_dir" "$changed"; then
            pal_log "error" "Cold start: failed to commit"
            return 1
        fi

        if pal_is_online; then
            local push_rc
            push_rc=0
            se_push "$repo_dir" || push_rc=$?
            if [ "$push_rc" -eq 2 ]; then
                pal_log "info" "Cold start: push deferred (offline)"
                was_offline=true
            elif [ "$push_rc" -eq 1 ]; then
                pal_log "error" "Cold start: push failed"
                return 1
            fi
        else
            was_offline=true
        fi
    else
        pal_log "info" "Cold start: nothing to commit"
    fi

    # Steps 8-9: Store commit hash and create sentinel (only if online)
    if [ "$was_offline" != "true" ]; then
        local head_hash
        head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
        if ! cs_store_commit "$repo_dir" "$head_hash"; then
            pal_log "error" "Cold start: failed to store commit hash"
            return 1
        fi
        if ! cs_create_sentinel "$repo_dir"; then
            pal_log "error" "Cold start: failed to create sentinel"
            return 1
        fi
    else
        pal_log "info" "Cold start: offline — sentinel deferred until next boot with connectivity"
    fi

    # Step 10: Done
    pal_log "info" "Cold start complete"
    return 0
}
