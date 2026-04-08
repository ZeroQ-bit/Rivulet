#!/bin/bash
#
# Orchestrates mock_plex_server + avio_seek_test under several scenarios.
# Each scenario: start server with specific knobs → run the client →
# kill the server → print the result line.
#
# Uses a per-scenario log file under /tmp so failures can be inspected.
#

set -u

cd "$(dirname "$0")"

SERVER_LOG=/tmp/mock_plex_server.log
SERVER_PID=""
PORT=18421

start_server() {
    # shellcheck disable=SC2086
    env MOCK_PORT=$PORT "$@" swift mock_plex_server.swift > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    # Wait for port to be ready
    for _ in $(seq 1 40); do
        if nc -z 127.0.0.1 $PORT 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    echo "server failed to start"; cat "$SERVER_LOG"; return 1
}

stop_server() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
    SERVER_PID=""
}

trap stop_server EXIT

run_scenario() {
    local name="$1"
    local scenario="$2"
    shift 2
    # Remaining args are env var overrides for the server
    stop_server
    if ! start_server "$@"; then return 1; fi
    echo
    echo "--- scenario: $name ---"
    env AVIO_TEST_URL="http://127.0.0.1:$PORT/" AVIO_TEST_BYTES=$((20*1024*1024)) swift avio_seek_test.swift "$scenario" 2>&1 | grep -E "^(===|result:|!!)"
    stop_server
}

# Baseline: fast localhost server, sequential reads.
run_scenario "healthy / sequential"  healthy \
    MOCK_TOTAL_BYTES=$((200*1024*1024)) MOCK_RATE_BPS=0

# Same, rate-limited to 100 Mbps.
run_scenario "100 Mbps cap / sequential" healthy \
    MOCK_TOTAL_BYTES=$((200*1024*1024)) MOCK_RATE_BPS=$((100*1024*1024/8))

# Truncation: server closes after 1 MB. Client should auto-restart.
run_scenario "truncation / sequential" truncating \
    MOCK_TOTAL_BYTES=$((200*1024*1024)) MOCK_TRUNCATE_AFTER=$((1024*1024))

# Seeky reader with drain-forward optimization.
run_scenario "seeky (drain-forward)" seeky \
    MOCK_TOTAL_BYTES=$((200*1024*1024)) MOCK_RATE_BPS=0

# Seeky reader WITHOUT drain — every seek restarts. The throughput delta
# between this and the one above is the win from the optimization.
run_scenario "seeky (legacy restart)" seeky-noop \
    MOCK_TOTAL_BYTES=$((200*1024*1024)) MOCK_RATE_BPS=0

# Seeky reader rate-limited + legacy path — models a real bandwidth-
# constrained server. The restart overhead should visibly collapse
# throughput here.
run_scenario "seeky (legacy, 100 Mbps cap)" seeky-noop \
    MOCK_TOTAL_BYTES=$((200*1024*1024)) MOCK_RATE_BPS=$((100*1024*1024/8))

run_scenario "seeky (drain, 100 Mbps cap)" seeky \
    MOCK_TOTAL_BYTES=$((200*1024*1024)) MOCK_RATE_BPS=$((100*1024*1024/8))

echo
echo "=== done ==="
