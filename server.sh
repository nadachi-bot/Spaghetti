#!/bin/bash
# Factorio Server Manager - start/stop/status script

PID_FILE=".server.pid"
HL_FILE="dist/server.hl"

cmd_start() {
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "Already running (PID $(cat "$PID_FILE"))"
        exit 0
    fi
    if [ ! -f "$HL_FILE" ]; then
        echo "Server binary not found. Run: haxe compile_server.hxml"
        exit 1
    fi
    echo "Starting server..."
    nohup hl "$HL_FILE" > .server.log 2>&1 &
    echo $! > "$PID_FILE"
    echo "Started (PID $!)"
}

cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Not running (no PID file)"
        exit 1
    fi
    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "Stopping (PID $pid)..."
        kill "$pid"
        rm -f "$PID_FILE"
        echo "Stopped"
    else
        echo "Not running (stale PID file)"
        rm -f "$PID_FILE"
    fi
}

cmd_status() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Not running (no PID file)"
        exit 1
    fi
    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "Running (PID $pid)"
    else
        echo "Not running (stale PID file)"
        rm -f "$PID_FILE"
    fi
}

cmd_logs() {
    if [ -f .server.log ]; then
        tail -f .server.log
    else
        echo "No log file found"
    fi
}

case "${1}" in
    start)  cmd_start  ;;
    stop)   cmd_stop   ;;
    status) cmd_status ;;
    logs)   cmd_logs   ;;
    *)
        echo "Usage: $0 {start|stop|status|logs}"
        exit 1
        ;;
esac
