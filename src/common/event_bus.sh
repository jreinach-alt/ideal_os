#!/bin/sh
set -e

# Ideal OS — File-Based Event Bus
# Append-only JSONL event log. Modules emit events; consumers tail/poll.
# No jq dependency — JSON constructed and parsed with printf/grep/sed.

# Guard against double-sourcing
if [ -n "$_EVENT_BUS_LOADED" ]; then
    return 0
fi
readonly _EVENT_BUS_LOADED=1

# Default event log path — override EVENT_LOG_DIR before sourcing for tests
EVENT_LOG_DIR="${EVENT_LOG_DIR:-/tmp/ideal_os/events}"
EVENT_LOG_FILE="${EVENT_LOG_DIR}/system-events.log"

# event_bus_init
#   Create event log directory and file if missing. Idempotent.
event_bus_init() {
    if [ ! -d "$EVENT_LOG_DIR" ]; then
        mkdir -p "$EVENT_LOG_DIR" || {
            printf 'event_bus_init: error: cannot create directory: %s\n' "$EVENT_LOG_DIR" >&2
            return 1
        }
    fi
    if [ ! -f "$EVENT_LOG_FILE" ]; then
        : > "$EVENT_LOG_FILE" || {
            printf 'event_bus_init: error: cannot create log file: %s\n' "$EVENT_LOG_FILE" >&2
            return 1
        }
    fi
    return 0
}

# event_bus_emit <source> <event_type> [payload_json]
#   Append a single event to the log file.
#   Timestamp is generated automatically (UTC ISO 8601).
#   payload_json defaults to {} if omitted.
event_bus_emit() {
    _eb_source="$1"
    _eb_type="$2"
    _eb_payload="${3:-{}}"

    if [ -z "$_eb_source" ]; then
        printf 'event_bus_emit: error: source is required\n' >&2
        return 1
    fi
    if [ -z "$_eb_type" ]; then
        printf 'event_bus_emit: error: event_type is required\n' >&2
        return 1
    fi

    if [ ! -f "$EVENT_LOG_FILE" ]; then
        printf 'event_bus_emit: error: log file does not exist (call event_bus_init first)\n' >&2
        return 1
    fi

    _eb_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    printf '{"_schema_version":"1.0","timestamp":"%s","source":"%s","event_type":"%s","payload":%s}\n' \
        "$_eb_ts" "$_eb_source" "$_eb_type" "$_eb_payload" >> "$EVENT_LOG_FILE" || {
        printf 'event_bus_emit: error: failed to append to log file\n' >&2
        return 1
    }

    return 0
}

# event_bus_read [--source <s>] [--type <t>] [--after <line_number>]
#   Read events from the log, optionally filtered.
#   --source: only events where "source":"<s>"
#   --type: only events where "event_type":"<t>"
#   --after N: skip first N lines (for resumption)
#   Prints matching events to stdout, one per line.
event_bus_read() {
    _eb_filter_source=""
    _eb_filter_type=""
    _eb_after=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                _eb_filter_source="$2"
                shift 2
                ;;
            --type)
                _eb_filter_type="$2"
                shift 2
                ;;
            --after)
                _eb_after="$2"
                shift 2
                ;;
            *)
                printf 'event_bus_read: error: unknown option: %s\n' "$1" >&2
                return 1
                ;;
        esac
    done

    if [ ! -f "$EVENT_LOG_FILE" ]; then
        printf 'event_bus_read: error: log file does not exist (call event_bus_init first)\n' >&2
        return 1
    fi

    # Start from the right line
    _eb_input=""
    if [ "$_eb_after" -gt 0 ]; then
        _eb_skip=$((_eb_after + 1))
        _eb_input="$(tail -n "+$_eb_skip" "$EVENT_LOG_FILE")"
    else
        _eb_input="$(cat "$EVENT_LOG_FILE")"
    fi

    # Apply filters
    if [ -n "$_eb_filter_source" ]; then
        _eb_input="$(printf '%s\n' "$_eb_input" | grep "\"source\":\"$_eb_filter_source\"" || true)"
    fi
    if [ -n "$_eb_filter_type" ]; then
        _eb_input="$(printf '%s\n' "$_eb_input" | grep "\"event_type\":\"$_eb_filter_type\"" || true)"
    fi

    # Output (skip empty)
    if [ -n "$_eb_input" ]; then
        printf '%s\n' "$_eb_input"
    fi

    return 0
}

# event_bus_count
#   Print the total number of events in the log.
event_bus_count() {
    if [ ! -f "$EVENT_LOG_FILE" ]; then
        printf '0'
        return 0
    fi

    # wc -l on an empty file returns 0
    _eb_count="$(wc -l < "$EVENT_LOG_FILE")"
    # Trim whitespace (some wc implementations pad)
    _eb_count="$(printf '%s' "$_eb_count" | tr -d ' ')"
    printf '%s' "$_eb_count"
}

# event_bus_validate <json_line>
#   Check that a JSON event line has all required fields.
#   Returns 0 if valid, 1 if missing required fields.
#   Does NOT validate JSON syntax — just checks field presence.
event_bus_validate() {
    _eb_line="$1"

    if [ -z "$_eb_line" ]; then
        return 1
    fi

    # Check each required field is present
    case "$_eb_line" in
        *'"_schema_version"'*) ;;
        *) return 1 ;;
    esac

    case "$_eb_line" in
        *'"timestamp"'*) ;;
        *) return 1 ;;
    esac

    case "$_eb_line" in
        *'"source"'*) ;;
        *) return 1 ;;
    esac

    case "$_eb_line" in
        *'"event_type"'*) ;;
        *) return 1 ;;
    esac

    case "$_eb_line" in
        *'"payload"'*) ;;
        *) return 1 ;;
    esac

    return 0
}
