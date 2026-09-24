#!/bin/bash
#
# Pulls and redeploys every running docker compose stack on this host, then prunes
# unused images. Every log entry is written as a single JSON line (JSONL) so the
# file can be shipped straight to OpenObserve.
#
# Optional environment overrides:
#   LOG_FILE          Path of the JSON log file
#   LOG_ENVIRONMENT   Value of the "environment" field (default: PROD)
#   LOG_SERVICE_NAME  Value of the "serviceName" field (default: update-docker-stacks-<host>)
#   TRACE_ID          Reuse an existing trace id (e.g. when called from another job)
#   PARENT_SPAN_ID    Parent span of this run within that trace

# Resolve the absolute directory where this script resides to ensure relative paths work in cron
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/stack_updates.json.log}"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Ensure the logs directory exists
mkdir -p "$(dirname "$LOG_FILE")"

HOST="$(hostname -s 2>/dev/null || hostname)"
RUN_USER="$(id -un 2>/dev/null || echo "${USER:-unknown}")"
ENVIRONMENT="${LOG_ENVIRONMENT:-PROD}"
SERVICE_NAME="${LOG_SERVICE_NAME:-update-docker-stacks-${HOST}}"

# ---------------------------------------------------------------------------
# JSON logging helpers (pure bash, no jq dependency)
# ---------------------------------------------------------------------------

# 32 hex chars, matching the trace/span id format of the other application
new_id() {
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}

now_iso() {
    date -u +%Y-%m-%dT%H:%M:%S.%6NZ
}

now_ms() {
    date +%s%3N
}

# Escape a string for inclusion inside a JSON string literal
json_escape() {
    local s
    # Drop control characters JSON can't carry raw (keeps \t, \n, \r for escaping below)
    s=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    printf '%s' "$s"
}

# Build a JSON object from key=value (string) and key:=value (raw number/bool/array) args
#   json_obj "host=web1" "exitCode:=0"  ->  {"host":"web1","exitCode":0}
json_obj() {
    local out="" pair key
    for pair in "$@"; do
        if [[ "$pair" == *":="* && "${pair%%:=*}" != *"="* ]]; then
            key=${pair%%:=*}
            out+=",\"$(json_escape "$key")\":${pair#*:=}"
        else
            key=${pair%%=*}
            out+=",\"$(json_escape "$key")\":\"$(json_escape "${pair#*=}")\""
        fi
    done
    printf '{%s}' "${out#,}"
}

TRACE_ID="${TRACE_ID:-$(new_id)}"
RUN_SPAN_ID="$(new_id)"
RUN_PARENT_SPAN_ID="${PARENT_SPAN_ID:-}"

# Span that log_event attributes entries to; switched per stack / cleanup step
SPAN_ID="$RUN_SPAN_ID"
PARENT_SPAN="$RUN_PARENT_SPAN_ID"

# log_event SEVERITY MESSAGE [PAYLOAD_JSON] [ERROR_TYPE]
# The payload is embedded as a JSON-encoded string to match the other application's schema.
log_event() {
    local severity=$1 message=$2 payload=${3:-} error_type=${4:-}
    if [ -z "$error_type" ]; then
        case "$severity" in
            DEBUG) error_type="Debug" ;;
            INFO)  error_type="Info" ;;
            WARN)  error_type="Warning" ;;
            ERROR) error_type="Error" ;;
            *)     error_type="$severity" ;;
        esac
    fi

    local line
    line=$(printf '{"timestamp":"%s","severity":"%s","trace_id":"%s","span_id":"%s","parent_span_id":"%s","environment":"%s","serviceName":"%s","errorType":"%s","payload":"%s","message":"%s"}' \
        "$(now_iso)" \
        "$severity" \
        "$TRACE_ID" \
        "$SPAN_ID" \
        "$PARENT_SPAN" \
        "$(json_escape "$ENVIRONMENT")" \
        "$(json_escape "$SERVICE_NAME")" \
        "$(json_escape "$error_type")" \
        "$(json_escape "$payload")" \
        "$(json_escape "$message")")

    printf '%s\n' "$line" >> "$LOG_FILE"

    local color=""
    case "$severity" in
        WARN)  color=$'\e[33m' ;;
        ERROR) color=$'\e[31m' ;;
    esac
    console "$message" "$color"
    return 0
}

# console MESSAGE [COLOR]
# Human-readable line (local time + message) when run by hand; cron has no TTY so prints nothing.
console() {
    [ -t 1 ] || return 0
    local color=${2:-}
    if [ -n "$color" ]; then
        printf '%s  %s%s\e[0m\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$color" "$1"
    else
        printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
    fi
}

# Start a child span of the run span
start_span() {
    SPAN_ID="$(new_id)"
    PARENT_SPAN="$RUN_SPAN_ID"
}

end_span() {
    SPAN_ID="$RUN_SPAN_ID"
    PARENT_SPAN="$RUN_PARENT_SPAN_ID"
}

# run_logged ERROR_TYPE DESCRIPTION CONTEXT_ARRAY_NAME -- COMMAND...
# Runs a command, capturing its output, exit code and duration into a single log entry.
run_logged() {
    local error_type=$1 description=$2 context_name=$3
    shift 4
    local -n context_ref="$context_name"

    local start rc output payload
    start=$(now_ms)
    # stdin from /dev/null so commands can't swallow the stack list the main loop reads
    output=$("$@" 2>&1 < /dev/null)
    rc=$?

    payload=$(json_obj "${context_ref[@]}" \
        "command=$*" \
        "exitCode:=$rc" \
        "durationMs:=$(( $(now_ms) - start ))" \
        "output=$output")

    if [ "$rc" -eq 0 ]; then
        log_event INFO "$description succeeded" "$payload"
    else
        log_event ERROR "$description failed (exit $rc)" "$payload" "$error_type"
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

RUN_START=$(now_ms)
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
COMPOSE_VERSION="$(docker compose version --short 2>/dev/null)"

log_event INFO "Run started on ${HOST}" "$(json_obj \
    "host=$HOST" \
    "user=$RUN_USER" \
    "scriptDir=$SCRIPT_DIR" \
    "bashVersion=$BASH_VERSION" \
    "dockerVersion=$DOCKER_VERSION" \
    "composeVersion=$COMPOSE_VERSION")"
console "Trace ID: ${TRACE_ID}  (full JSON log: ${LOG_FILE})"

if ! compose_json=$(docker compose ls --format json 2>&1); then
    log_event ERROR "Unable to list running compose projects" \
        "$(json_obj "host=$HOST" "output=$compose_json")" "DockerUnavailable"
    exit 1
fi

stacks_total=0
stacks_ok=0
failed_stacks=()

# Each running compose project is one {...} object in the JSON array
while IFS= read -r entry; do
    project=$(printf '%s' "$entry" | grep -o '"Name":"[^"]*"' | cut -d'"' -f4)
    config_path=$(printf '%s' "$entry" | grep -o '"ConfigFiles":"[^"]*"' | cut -d'"' -f4)

    # Extract directory from config path (handles multi-config CSV formats)
    first_config=$(echo "$config_path" | cut -d',' -f1)
    stack_dir=$(dirname "$first_config")

    start_span
    stack_ctx=("host=$HOST" "stack=$project" "stackDir=$stack_dir" "configFiles=$config_path")

    if [ ! -d "$stack_dir" ]; then
        log_event WARN "Skipping stack ${project}: directory ${stack_dir} not found" \
            "$(json_obj "${stack_ctx[@]}")" "StackDirMissing"
        end_span
        continue
    fi

    stacks_total=$((stacks_total + 1))
    stack_start=$(now_ms)
    log_event INFO "Processing stack ${project}" "$(json_obj "${stack_ctx[@]}")"

    if ! cd "$stack_dir"; then
        log_event ERROR "Unable to enter ${stack_dir}" "$(json_obj "${stack_ctx[@]}")" "StackDirInaccessible"
        failed_stacks+=("$project")
        end_span
        continue
    fi

    if run_logged "PullFailed" "Image pull for ${project}" stack_ctx -- docker compose --ansi never pull \
        && run_logged "DeployFailed" "Deploy of ${project}" stack_ctx -- docker compose --ansi never up -d; then
        stacks_ok=$((stacks_ok + 1))
        stack_status="success"
        stack_severity=INFO
    else
        failed_stacks+=("$project")
        stack_status="failed"
        stack_severity=ERROR
    fi

    log_event "$stack_severity" "Stack ${project} finished: ${stack_status}" "$(json_obj "${stack_ctx[@]}" \
        "status=$stack_status" \
        "durationMs:=$(( $(now_ms) - stack_start ))")" \
        "$([ "$stack_status" = failed ] && echo StackUpdateFailed)"

    cd "$SCRIPT_DIR" || true
    end_span
done < <(printf '%s' "$compose_json" | grep -o '{[^}]*}')

start_span
prune_ctx=("host=$HOST")
run_logged "PruneFailed" "Image cleanup" prune_ctx -- docker image prune -f
end_span

# Build a JSON array of failed stack names for the summary
failed_json=""
for s in "${failed_stacks[@]}"; do
    failed_json+=",\"$(json_escape "$s")\""
done
failed_json="[${failed_json#,}]"

if [ "${#failed_stacks[@]}" -eq 0 ]; then
    summary_severity=INFO
    summary_type=""
else
    summary_severity=ERROR
    summary_type="RunCompletedWithErrors"
fi

log_event "$summary_severity" \
    "Run completed on ${HOST}: ${stacks_ok}/${stacks_total} stacks updated, ${#failed_stacks[@]} failed" \
    "$(json_obj \
        "host=$HOST" \
        "stacksTotal:=$stacks_total" \
        "stacksSucceeded:=$stacks_ok" \
        "stacksFailed:=${#failed_stacks[@]}" \
        "failedStacks:=$failed_json" \
        "durationMs:=$(( $(now_ms) - RUN_START ))")" \
    "$summary_type"
console "Trace ID: ${TRACE_ID}"

[ "${#failed_stacks[@]}" -eq 0 ]
