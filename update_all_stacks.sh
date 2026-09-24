#!/bin/bash
#
# Pulls and redeploys every running docker compose stack on this host, then prunes
# unused images. Every log entry is written as a single JSON line (JSONL) so the
# file can be shipped straight to OpenObserve.
#
# Logs go to one file per day (logs/stack_updates-YYYY-MM-DD.json.log); files older than
# LOG_RETENTION_DAYS are deleted at the start of each run.
#
# Optional environment overrides:
#   LOG_DIR             Directory for the daily log files (default: <script dir>/logs)
#   LOG_RETENTION_DAYS  Days of log files to keep, including today (default: 5)
#   LOG_ENVIRONMENT   Value of the "environment" field (default: PROD)
#   LOG_SERVICE_NAME  Value of the "serviceName" field (default: update-docker-stacks-<host>)
#   TRACE_ID          Reuse an existing trace id (e.g. when called from another job)
#   PARENT_SPAN_ID    Parent span of this run within that trace

# Resolve the absolute directory where this script resides to ensure relative paths work in cron
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/logs}"
LOG_PREFIX="stack_updates-"
LOG_SUFFIX=".json.log"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-5}"
LOG_FILE="${LOG_DIR}/${LOG_PREFIX}$(date +%F)${LOG_SUFFIX}"

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Ensure the logs directory exists
mkdir -p "$LOG_DIR"

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

# Build a JSON array of strings from the arguments
json_str_array() {
    local out="" s
    for s in "$@"; do
        out+=",\"$(json_escape "$s")\""
    done
    printf '[%s]' "${out#,}"
}

# Delete daily log files older than LOG_RETENTION_DAYS (today counts as day 1).
# Dates are taken from the file name, so only files this script created are touched.
cleanup_old_logs() {
    if ! [[ "$LOG_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
        log_event WARN "Log cleanup skipped: LOG_RETENTION_DAYS '${LOG_RETENTION_DAYS}' is not a positive number" \
            "$(json_obj "host=$HOST" "logDir=$LOG_DIR")" "LogCleanupSkipped"
        return 0
    fi

    # Oldest date to keep; anything earlier is deleted (ISO dates compare correctly as strings)
    local keep_from f file_date
    local -a deleted=() failed=()
    keep_from=$(date -d "-$((LOG_RETENTION_DAYS - 1)) days" +%F)

    for f in "$LOG_DIR/$LOG_PREFIX"*"$LOG_SUFFIX"; do
        [ -e "$f" ] || continue
        file_date=${f##*/"$LOG_PREFIX"}
        file_date=${file_date%"$LOG_SUFFIX"}
        [[ "$file_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue

        if [[ "$file_date" < "$keep_from" ]]; then
            if rm -f -- "$f"; then
                deleted+=("${f##*/}")
            else
                failed+=("${f##*/}")
            fi
        fi
    done

    local payload
    payload=$(json_obj "host=$HOST" "logDir=$LOG_DIR" "retentionDays:=$LOG_RETENTION_DAYS" \
        "keepFrom=$keep_from" "deletedFiles:=$(json_str_array "${deleted[@]}")" \
        "failedFiles:=$(json_str_array "${failed[@]}")")

    if [ "${#failed[@]}" -gt 0 ]; then
        log_event WARN "Log cleanup could not delete ${#failed[@]} file(s)" "$payload" "LogCleanupFailed"
    elif [ "${#deleted[@]}" -gt 0 ]; then
        log_event INFO "Log cleanup deleted ${#deleted[@]} file(s) older than ${keep_from}" "$payload"
    fi
}

short_id() {
    local id=${1#sha256:}
    printf '%s' "${id:0:12}"
}

# describe_image IMAGE_ID
# Sets IMG_VERSION (from OCI / label-schema labels, may be empty), IMG_CREATED (YYYY-MM-DD)
# and IMG_LABEL (human-readable "version, built date" or "id, built date").
describe_image() {
    local oci schema created
    IFS='|' read -r oci schema created < <(docker image inspect -f \
        '{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "org.label-schema.version"}}|{{.Created}}' \
        "$1" 2>/dev/null < /dev/null)
    [ "$oci" = "<no value>" ] && oci=""
    [ "$schema" = "<no value>" ] && schema=""
    IMG_VERSION=${oci:-$schema}
    IMG_CREATED=${created%%T*}
    IMG_LABEL="${IMG_VERSION:-id $(short_id "$1")}, built ${IMG_CREATED:-unknown}"
}

# check_containers STACK_NAME CONTEXT_ARRAY_NAME
# Run inside a stack dir after a pull. For every running container, compares the image it
# was started from with the image its tag now points to and logs one line per container,
# then a stack-level summary.
# Sets OUTDATED_CONTAINERS (names) and PENDING_IMAGE / PENDING_CHANGE (keyed by name)
# for verify_updates.
check_containers() {
    local stack=$1
    local -n ctx_ref="$2"
    OUTDATED_CONTAINERS=()
    declare -gA PENDING_IMAGE=() PENDING_CHANGE=()

    local entries="" checked=0 cid name ref running_id latest_id
    local status cur_version cur_created cur_label new_version new_created new_label log_msg payload
    local -a detail
    while IFS= read -r cid; do
        [ -n "$cid" ] || continue
        IFS='|' read -r name ref running_id \
            < <(docker inspect -f '{{.Name}}|{{.Config.Image}}|{{.Image}}' "$cid" 2>/dev/null < /dev/null)
        name=${name#/}
        latest_id=$(docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null < /dev/null)
        checked=$((checked + 1))

        describe_image "$running_id"
        cur_version=$IMG_VERSION cur_created=$IMG_CREATED cur_label=$IMG_LABEL
        new_version="" new_created="" new_label=""

        if [ -z "$latest_id" ]; then
            status="unknown"
            log_msg="[${stack}] ${name} (${ref}): could not resolve image tag, running ${cur_label}"
        elif [ "$latest_id" = "$running_id" ]; then
            status="up-to-date"
            log_msg="[${stack}] ${name} (${ref}): up to date, ${cur_label}"
        else
            status="update-available"
            describe_image "$latest_id"
            new_version=$IMG_VERSION new_created=$IMG_CREATED new_label=$IMG_LABEL
            log_msg="[${stack}] ${name} (${ref}): update available, ${cur_label} -> ${new_label}"
            OUTDATED_CONTAINERS+=("$name")
            PENDING_IMAGE[$name]=$latest_id
            PENDING_CHANGE[$name]="${cur_label} -> ${new_label}"
        fi

        detail=("container=$name" "image=$ref" "status=$status" \
            "runningImageId=${running_id#sha256:}" "runningVersion=$cur_version" "runningImageCreated=$cur_created" \
            "latestImageId=${latest_id#sha256:}" "latestVersion=$new_version" "latestImageCreated=$new_created")
        entries+=",$(json_obj "${detail[@]}")"
        log_event INFO "$log_msg" "$(json_obj "${ctx_ref[@]}" "${detail[@]}")"
    done < <(docker compose ps -q 2>/dev/null < /dev/null)

    local count=${#OUTDATED_CONTAINERS[@]}
    payload=$(json_obj "${ctx_ref[@]}" \
        "containersChecked:=$checked" \
        "containersNeedingUpdateCount:=$count" \
        "containers:=[${entries#,}]")

    if [ "$count" -gt 0 ]; then
        local joined
        printf -v joined '%s, ' "${OUTDATED_CONTAINERS[@]}"
        log_event INFO "Stack ${stack}: ${count} of ${checked} container(s) need updating: ${joined%, }" "$payload"
    else
        log_event INFO "Stack ${stack}: all ${checked} container(s) up to date" "$payload"
    fi
}

# verify_updates STACK_NAME CONTEXT_ARRAY_NAME
# Run after `up -d`. Confirms each outdated container is now running the new image.
# Sets UPDATED_CONTAINERS to the names that were successfully updated.
verify_updates() {
    local stack=$1
    local -n ctx_ref="$2"
    UPDATED_CONTAINERS=()

    local name now_id payload
    for name in "${OUTDATED_CONTAINERS[@]}"; do
        now_id=$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null < /dev/null)
        payload=$(json_obj "${ctx_ref[@]}" "container=$name" \
            "expectedImageId=${PENDING_IMAGE[$name]#sha256:}" "runningImageId=${now_id#sha256:}" \
            "change=${PENDING_CHANGE[$name]}")
        if [ "$now_id" = "${PENDING_IMAGE[$name]}" ]; then
            UPDATED_CONTAINERS+=("$name")
            log_event INFO "[${stack}] ${name} updated: ${PENDING_CHANGE[$name]}" "$payload"
        else
            log_event WARN "[${stack}] ${name} is still running the old image after deploy" "$payload" "UpdateNotApplied"
        fi
    done
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
cleanup_old_logs

if ! compose_json=$(docker compose ls --format json 2>&1); then
    log_event ERROR "Unable to list running compose projects" \
        "$(json_obj "host=$HOST" "output=$compose_json")" "DockerUnavailable"
    exit 1
fi

stacks_total=0
stacks_ok=0
failed_stacks=()
stacks_needing_update=()
updates_json=""    # "stack":["container",...] pairs for the summary
containers_updated=0

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

    OUTDATED_CONTAINERS=()
    UPDATED_CONTAINERS=()
    if run_logged "PullFailed" "Image pull for ${project}" stack_ctx -- docker compose --ansi never pull \
        && check_containers "$project" stack_ctx \
        && run_logged "DeployFailed" "Deploy of ${project}" stack_ctx -- docker compose --ansi never up -d; then
        verify_updates "$project" stack_ctx
        containers_updated=$((containers_updated + ${#UPDATED_CONTAINERS[@]}))
        stacks_ok=$((stacks_ok + 1))
        stack_status="success"
        stack_severity=INFO
    else
        failed_stacks+=("$project")
        stack_status="failed"
        stack_severity=ERROR
    fi

    if [ "${#OUTDATED_CONTAINERS[@]}" -gt 0 ]; then
        stacks_needing_update+=("$project")
        updates_json+=",\"$(json_escape "$project")\":$(json_str_array "${OUTDATED_CONTAINERS[@]}")"
    fi

    log_event "$stack_severity" "Stack ${project} finished: ${stack_status}" "$(json_obj "${stack_ctx[@]}" \
        "status=$stack_status" \
        "containersNeedingUpdate:=$(json_str_array "${OUTDATED_CONTAINERS[@]}")" \
        "containersUpdated:=$(json_str_array "${UPDATED_CONTAINERS[@]}")" \
        "durationMs:=$(( $(now_ms) - stack_start ))")" \
        "$([ "$stack_status" = failed ] && echo StackUpdateFailed)"

    cd "$SCRIPT_DIR" || true
    end_span
done < <(printf '%s' "$compose_json" | grep -o '{[^}]*}')

start_span
prune_ctx=("host=$HOST")
run_logged "PruneFailed" "Image cleanup" prune_ctx -- docker image prune -f
end_span

if [ "${#stacks_needing_update[@]}" -gt 0 ]; then
    printf -v updated_list '%s, ' "${stacks_needing_update[@]}"
    log_event INFO "Stacks with updates: ${updated_list%, }" "$(json_obj \
        "host=$HOST" \
        "stacksNeedingUpdateCount:=${#stacks_needing_update[@]}" \
        "stacksNeedingUpdate:={${updates_json#,}}")"
else
    log_event INFO "No stacks had updates available" "$(json_obj "host=$HOST" "stacksNeedingUpdateCount:=0")"
fi

if [ "${#failed_stacks[@]}" -eq 0 ]; then
    summary_severity=INFO
    summary_type=""
else
    summary_severity=ERROR
    summary_type="RunCompletedWithErrors"
fi

log_event "$summary_severity" \
    "Run completed on ${HOST}: ${stacks_ok}/${stacks_total} stacks processed, ${#stacks_needing_update[@]} had updates, ${containers_updated} container(s) updated, ${#failed_stacks[@]} failed" \
    "$(json_obj \
        "host=$HOST" \
        "stacksTotal:=$stacks_total" \
        "stacksSucceeded:=$stacks_ok" \
        "stacksFailed:=${#failed_stacks[@]}" \
        "failedStacks:=$(json_str_array "${failed_stacks[@]}")" \
        "stacksNeedingUpdate:={${updates_json#,}}" \
        "containersUpdated:=$containers_updated" \
        "durationMs:=$(( $(now_ms) - RUN_START ))")" \
    "$summary_type"
console "Trace ID: ${TRACE_ID}"

[ "${#failed_stacks[@]}" -eq 0 ]
