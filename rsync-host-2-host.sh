#!/bin/sh
# ===========================================================================================
# Rsync HOST-2-HOST Robust Replication Script
# Author: David Harrop
# Date:   September 2025
#
# Supports ESXi, Busybox & GNU Linux
# Run this script from the SOURCE host
#
# Usage:
#   [--fast | --safe] [--dry-run] [--checksum | --checksum-type=<algo>] [--no-excludes]
#
# Modes:
#   Fast Mode:
#     - Best for high-bandwidth, low-latency networks
#     - Recommended when using local or networked filesystems
#     - Useful if CPU is the limiting factor
#     - Uses the --whole-file flag
#     - Skips partial verification (relies on ssh & underlying filesystems for integrity)
#     - Falls back to Safe Mode automatically on error
#
#   Safe Mode:
#     - Best for lower-bandwidth or unstable networks
#     - Safer when interruptions may occur
#     - Uses the --append-verify flag:
#     	    - Appends new data, then validates the entire file with checksums
#     	    - Supports resuming from interrupted transfers
#
# Excludes:
#   - An exclude file can be used omit irrelevant files from replication.
#   - Use --no-excludes to override and replicate all files.
#
# Checksum Verification:
#   - --append-verify (safe mode) ensures appended data is validated during copy.
#     For belt and braces assurance and to ensure the finished copy integrity, run with:
#     --checksum or --checksum-type=<algo> to choose the checksum algorithm
#     This script assumes rysnc support for: md5, md4, sha1, sha256, sha512,
#     xxh64, xxh128, xxh3 (default: xxh3)
#   - Checkums help detect silent corruption and ensure end-to-end integrity,
#     especially when timestamps are unreliable, or files may have changed during copy.
#	- In FAST mode with --checksum: since FAST mode uses --whole-file and --ignore-existing,
#     destination files are not verified during the initial copy. A separate checksum 
#     validation step will run after the transfer to ensure data integrity.
#
# Cleanup:
#   - To preserve resources this script automatically cleans up any stale rsync processes
#    on start, exit, or Ctrl+C (both locally and on the remote host).
#    Warning: This script will stop any other rsync processes not launched by this script. 
# ===========================================================================================

# Paths, hosts & defaults
SOURCE_DIR="/vmfs/volumes/Host1SourceDatastore/"                  # Source location on SOURCE host
DEST_DIR="/vmfs/volumes/Host2DestDatastore/"                      # Destination location on DEST host
DEST_HOST="root@192.168.1.20"                                     # Destination host ssh login
PRIVKEY="/vmfs/volumes/Host1SourceDatastore/privkey"              # SSH private key stored on SOURCE
SOURCE_RSYNC_BIN="/vmfs/volumes/Host1SourceDatastore/rsync"       # SORCE rsync binary location
DEST_RSYNC_BIN="/vmfs/volumes/Host2DestDatastore/rsync"           # DEST rsync binary location
EXCLUDE_FILE="/vmfs/volumes/Datastore1/rsync_excludes.txt"        # Optional filter, one entry per line
LOG_DIR="/vmfs/volumes/Datastore1/rsync_logs"                     # SOURCE host log location
LOG_FILE="${LOG_DIR}/rsync_$(date '+%Y%m%d_%H%M%S').log"          # Log file name and format
RSYNC_MODE="${RSYNC_MODE:-SAFE}"                                  # Set rsync mode flag: FAST --whole-file --ignore-existing | SAFE --append-verify
RSYNC_FLAGS="-rltDv --progress --sparse --partial"                # Default rsync flags
RSYNC_TIMEOUT=5 						  # Failback to SAFE mode on poor network. (May need to increase with --checksum) 
RETRY_DELAY=10							  # Seconds between rsync retries (script retries infinitely)  
CHECKSUM=0                                                        # Script default use checksums?: 0=no, 1=yes
CHECKSUM_TYPE="xxh3"                                              # Script default checksum algorithm
CHECKSUM_LIST="md5 md4 sha1 sha256 sha512 xxh64 xxh128 xxh3 none" # Valid checksum algorithms

# Logging
mkdir -p "$LOG_DIR" || {
    echo "Failed to create log directory $LOG_DIR"
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" | tee -a "$LOG_FILE"
}

# Log header info
echo "=================================================================================" | tee -a "$LOG_FILE"
echo "ESXi rsync replication script started at $(date)" | tee -a "$LOG_FILE"
echo "Rsync Mode: $RSYNC_MODE" | tee -a "$LOG_FILE"
echo "=================================================================================" | tee -a "$LOG_FILE"

# Preliminary checks
[ -x "$SOURCE_RSYNC_BIN" ] || { log "Source rsync not found: $SOURCE_RSYNC_BIN"; exit 1; }
[ -f "$PRIVKEY" ] || { log "SSH private key not found: $PRIVKEY"; exit 1; }

# SSH command wrapper
ssh_exec() {
    ssh -i "$PRIVKEY" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$DEST_HOST" "$@"
}

# Safely kill
kill_process() {
    pid=$1
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
}

kill_rsync_local() {
    # Protect current shell and session
    SELF_PID=$$
    SELF_PPID=$PPID

    # Detect ESXi / BusyBox vs Linux
    if ps -z >/dev/null 2>&1; then
        
        # Kill all live rsync processes except script and parent
        ps | grep rsync | grep -v grep | while read -r pid rest; do
            [ "$pid" = "$SELF_PID" ] && continue
            [ "$pid" = "$SELF_PPID" ] && continue
            echo "Killing rsync PID $pid"
            kill_process "$pid"
        done

        # Kill zombie rsync processes by killing their parent
        ps -z | grep rsync | while read -r zombie_pid parent_pid rest; do
            [ "$parent_pid" -ne 1 ] && [ "$parent_pid" != "$SELF_PID" ] && [ "$parent_pid" != "$SELF_PPID" ] && {
                echo "Zombie $zombie_pid detected, killing parent $parent_pid"
                kill_process "$parent_pid"
            }
        done

    else
        # Kill all live rsync processes except script and parent
        ps aux | grep rsync | grep -v grep | while read -r line; do
            pid=$(echo "$line" | awk '{print $2}')
            [ "$pid" = "$SELF_PID" ] && continue
            [ "$pid" = "$SELF_PPID" ] && continue
            echo "Killing rsync PID $pid"
            kill_process "$pid"
        done

        # Kill zombie rsync processes by parent
        ps aux | awk '$8=="Z" && $11~/rsync/ {print $2}' | while read -r zombie; do
            parent=$(ps -o ppid= -p "$zombie" 2>/dev/null | tr -d ' ')
            if [ -n "$parent" ] && [ "$parent" -ne 1 ] && [ "$parent" != "$SELF_PID" ] && [ "$parent" != "$SELF_PPID" ]; then
                echo "Zombie $zombie detected, killing parent $parent"
                kill_process "$parent"
            fi
        done
    fi
}

kill_rsync_remote() {
    # Fetch all remote rsync PIDs
    remote_pids=$(ssh_exec 'ps | grep "[r]sync" | awk "{print \$1}"')

    # Echo locally for each PID
    for pid in $remote_pids; do
        echo "Killing leftover (remote) rsync PID $pid"
    done

    # Send SSH command to kill
    ssh_exec "
        for pid in $remote_pids; do
            kill \$pid 2>/dev/null || true
        done
        for pid in $remote_pids; do
            ps | grep -q \"^\\\$pid\$\" && kill -9 \$pid 2>/dev/null || true
        done
    "
}

# Start main script
[ -t 1 ] && clear
echo
echo "==========================================================================================="
echo "Rsync HOST-2-HOST Robust Replication Script"
echo "from Itiligent"
echo
echo "Usage: [--fast | --safe] [--dry-run] [--checksum | --checksum-type=<algo>] [--no-excludes]"
echo

DRY_RUN=0
NO_EXCLUDES=0
#Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
    --fast)
        RSYNC_MODE="FAST"
        ;;
    --safe)
        RSYNC_MODE="SAFE"
        ;;
    --dry-run)
        DRY_RUN=1
        ;;
    --checksum)
        CHECKSUM=1
        ;;
    --checksum-type=*)
        CHECKSUM_TYPE="${1#*=}"
        CHECKSUM=1
        ;;
    --no-excludes)
        NO_EXCLUDES=1
        ;;
    -h | --help)
        echo
        echo "Usage: $0 [--fast | --safe] [--dry-run] [--checksum --checksum-type=<algo>] [--no-excludes]"
        echo
        echo "  --fast       Run rsync in whole-file mode (no partial verification)"
        echo "  --safe       Run rsync in append-verify mode (slower, safer)"
        echo "  --dry-run    Test run without copying files"
        echo "  --checksum   Enable checksum comparison (very slow)"
        echo "  --checksum-type=<see checksum list>"
        echo "  --no-exlcudes Ignore existing excludes file"
         echo
        exit 1
        ;;
    *)
        echo "Unknown argument: $1"
        echo "Usage: $0 [--fast | --safe] [--dry-run] [--checksum]"
        exit 1
        ;;
    esac
    shift
done

[ $DRY_RUN -eq 1 ] && echo "Dry-run enabled"
echo "Rsync Mode: $RSYNC_MODE"
[ $CHECKSUM -eq 1 ] && case " $CHECKSUM_LIST " in
*" $CHECKSUM_TYPE "*) ;; 
*) echo "ERROR: Invalid checksum type: $CHECKSUM_TYPE"; exit 1 ;;
esac
[ $CHECKSUM -eq 1 ] && echo "Checksum mode enabled (slower)"
echo "Log file: $LOG_FILE"
echo "==========================================================================================="
echo

# Cleanup process handler
CLEANUP_DONE=0
cleanup_all() {
    [ "$CLEANUP_DONE" -eq 1 ] && return 0
    CLEANUP_DONE=1
    echo "Running rsync cleanup... (local & remote)"
    echo
    kill_rsync_local
    kill_rsync_remote
}

# At script start, check for and quietly kill any orphand rsync proceses (local and remote)
trap 'cleanup_all; exit 1' INT TERM
trap 'cleanup_all' EXIT

kill_rsync_local
kill_rsync_remote

ssh_exec "mkdir -p \"${DEST_DIR}\"" || { log "Failed to create remote destination directory"; exit 1; }

do_rsync() {
    MODE="$1"
    
	# Trigger dry-run
    [ $DRY_RUN -eq 1 ] && RSYNC_FLAGS="$RSYNC_FLAGS --dry-run"

    # Skip checksum flag in FAST mode (handled in a separate FAST mode step)
	if [ "$CHECKSUM" -eq 1 ]; then
        if [ "$RSYNC_MODE" = "FAST" ]; then
            log "Checksum verification will be performed after FAST mode sync"
        else
            RSYNC_FLAGS="$RSYNC_FLAGS --checksum"
            [ "$CHECKSUM_TYPE" != "none" ] && RSYNC_FLAGS="$RSYNC_FLAGS --checksum-choice=$CHECKSUM_TYPE"
            log "Checksum enabled in SAFE mode: ${CHECKSUM_TYPE:-default}"
        fi
    fi

    # Handle excludes
	RSYNC_EXCLUDES=""
    if [ "$NO_EXCLUDES" -eq 0 ] && [ -f "$EXCLUDE_FILE" ] && [ -s "$EXCLUDE_FILE" ]; then
        RSYNC_EXCLUDES="--exclude-from=$EXCLUDE_FILE"
        log "Using exclude file: $EXCLUDE_FILE"
    elif [ "$NO_EXCLUDES" -eq 1 ]; then
        log "Ignoring exclude file (--no-excludes set), copying everything"
    else
        log "No exclude file found or empty; copying everything"
    fi

    SSH_OPTS="-i \"$PRIVKEY\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

    case "$MODE" in
        FAST)
            # Run in FAST mode
			log "Running rsync with --whole-file flag"
            echo "     Source:${SOURCE_DIR}"
            echo "Destination:${DEST_HOST}/${DEST_DIR}"
            "${SOURCE_RSYNC_BIN}" ${RSYNC_FLAGS} --timeout=$RSYNC_TIMEOUT --whole-file --ignore-existing \
                ${RSYNC_EXCLUDES} \
                -e "ssh $SSH_OPTS" \
                --rsync-path="${DEST_RSYNC_BIN}" \
                "$SOURCE_DIR" "${DEST_HOST}:${DEST_DIR}"
            STATUS=$?

            # Failover if FAST copy errors
            if [ $STATUS -ne 0 ]; then
                log "FAST mode (copy phase) failed (exit $STATUS). Failing over to SAFE mode..."
                echo "     Source:${SOURCE_DIR}"
                echo "Destination:${DEST_HOST}/${DEST_DIR}"
                "${SOURCE_RSYNC_BIN}" ${RSYNC_FLAGS} --timeout=$RSYNC_TIMEOUT --append-verify \
                    ${RSYNC_EXCLUDES} \
                    -e "ssh $SSH_OPTS" \
                    --rsync-path="${DEST_RSYNC_BIN}" \
                    "$SOURCE_DIR" "${DEST_HOST}:${DEST_DIR}"
                return $?
            fi

			# Optional checksum validation after FAST copy
            if [ $CHECKSUM -eq 1 ] && [ $MODE = "FAST" ]; then
                log "Verifying destination files with $CHECKSUM_TYPE checksum"
                echo "     Source:${SOURCE_DIR}"
                echo "Destination:${DEST_HOST}/${DEST_DIR}"
                "${SOURCE_RSYNC_BIN}" $RSYNC_FLAGS --timeout=$((RSYNC_TIMEOUT * 10)) --checksum \
                    $RSYNC_EXCLUDES \
                    -e "ssh $SSH_OPTS" \
                    --rsync-path="${DEST_RSYNC_BIN}" \
                    "$SOURCE_DIR" "${DEST_HOST}:${DEST_DIR}"
                STATUS=$?

			   # Failover to SAFE mode
			   if [ $STATUS -ne 0 ]; then
                    log "FAST mode (checksum phase) failed (exit $STATUS). Failing over to SAFE mode..."
                    echo "     Source:${SOURCE_DIR}"
                    echo "Destination:${DEST_HOST}/${DEST_DIR}"
                    "${SOURCE_RSYNC_BIN}" ${RSYNC_FLAGS} --timeout=$RSYNC_TIMEOUT --append-verify \
                        ${RSYNC_EXCLUDES} \
                        -e "ssh $SSH_OPTS" \
                        --rsync-path="${DEST_RSYNC_BIN}" \
                        "$SOURCE_DIR" "${DEST_HOST}:${DEST_DIR}"
                    return $?
                fi
            fi
            return $STATUS
            ;;
        SAFE)
			# Run in SAFE mode
            log "Running rsync with --append-verify flag"
            echo "     Source:${SOURCE_DIR}"
            echo "Destination:${DEST_HOST}/${DEST_DIR}"
            "${SOURCE_RSYNC_BIN}" ${RSYNC_FLAGS} --timeout=$RSYNC_TIMEOUT --append-verify \
                ${RSYNC_EXCLUDES} \
                -e "ssh $SSH_OPTS" \
                --rsync-path="${DEST_RSYNC_BIN}" \
                "$SOURCE_DIR" "${DEST_HOST}:${DEST_DIR}"
            return $?
            ;;
    esac
}

# Infinite retry loop
CURRENT_MODE="$RSYNC_MODE"
attempt=1

while true; do
    log "============================="
    log "Rsync attempt #$attempt (mode: $(echo "$CURRENT_MODE"))"
    log "============================="

    # Re run rsync for each attempt
    do_rsync "$CURRENT_MODE"
    RSYNC_EXIT=$?

    if [ $RSYNC_EXIT -eq 0 ]; then
        log "Rsync completed successfully at $(date '+%Y-%m-%d %H:%M:%S')"
        break  # Exit loop on success
    fi

    # If FAST mode failed, fall back to SAFE mode and continue with SAFE mode for subsequent retries
    if [ "$CURRENT_MODE" = "FAST" ]; then
        log "FAST mode failed (exit $RSYNC_EXIT). Switching to SAFE mode for next attempt..."
        CURRENT_MODE="SAFE"
    else
        log "Safe mode failed with exit code $RSYNC_EXIT. Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    fi

    attempt=$((attempt + 1))
done
log "Rsync finished successfully. Exiting."
cleanup_all
exit 0
