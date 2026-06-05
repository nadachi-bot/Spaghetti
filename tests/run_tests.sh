#!/bin/bash
# Integration test runner for FactorioServerRunner
# Usage: ./run_tests.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
API_BASE="http://localhost:8080"
SERVER_PID=""
TEST_SERVER_IDS=""  # Track created server IDs for cleanup
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

track_server_id() {
    TEST_SERVER_IDS="$TEST_SERVER_IDS $1"
}

cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"

    # Stop and delete any tracked test server instances via the API
    if [ -n "$TEST_SERVER_IDS" ]; then
        for sid in $TEST_SERVER_IDS; do
            echo "  Stopping test instance $sid..."
            curl -s -X POST "$API_BASE/api/servers/$sid/stop" > /dev/null 2>&1 || true
            sleep 1
            echo "  Deleting test instance $sid..."
            curl -s -X DELETE "$API_BASE/api/servers/$sid" > /dev/null 2>&1 || true
            # Also remove config file directly in case API delete failed
            rm -f "$PROJECT_DIR/data/config/instances/$sid.json"
            rm -f "$PROJECT_DIR/data/config/instances/settings-$sid.json"
        done
    fi

    # Kill the server process
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

assert_equals() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $test_name (expected: $expected, actual: $actual)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_contains() {
    local test_name="$1"
    local haystack="$2"
    local needle="$3"
    
    if echo "$haystack" | grep -q "$needle"; then
        echo -e "  ${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} $test_name (expected to contain: $needle)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_http_status() {
    local test_name="$1"
    local expected_status="$2"
    local url="$3"
    local method="${4:-GET}"
    local body="${5:-}"
    
    local status_code
    if [ "$method" = "GET" ]; then
        status_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    elif [ "$method" = "POST" ]; then
        status_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$body" "$url")
    elif [ "$method" = "PUT" ]; then
        status_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" -d "$body" "$url")
    elif [ "$method" = "DELETE" ]; then
        status_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$url")
    fi
    
    assert_equals "$test_name" "$expected_status" "$status_code"
}

echo "============================================"
echo "FactorioServerRunner Integration Tests"
echo "============================================"
echo ""

# --------------------------------------------------
# Build the server first
# --------------------------------------------------
echo -e "${YELLOW}Building server...${NC}"
cd "$PROJECT_DIR"
haxe compile_server.hxml
if [ $? -ne 0 ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi
echo -e "${GREEN}Build successful${NC}"
echo ""

# --------------------------------------------------
# Ensure test save exists
# ------------------------------------------------–
echo -e "${YELLOW}Verifying test save file...${NC}"
if [ ! -f "$PROJECT_DIR/data/saves/1780434878_5895/game_save.zip" ]; then
    echo -e "${RED}Test save file not found!${NC}"
    exit 1
fi
echo -e "${GREEN}Test save file exists${NC}"
echo ""

# --------------------------------------------------
# Start the server
# --------------------------------------------------
echo -e "${YELLOW}Starting server...${NC}"
cd "$PROJECT_DIR"
hl dist/server.hl &
SERVER_PID=$!
sleep 3  # Wait for server to start

# Verify server is running
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo -e "${RED}Server failed to start!${NC}"
    exit 1
fi
echo -e "${GREEN}Server started (PID: $SERVER_PID)${NC}"
echo ""

# --------------------------------------------------
# Test 1: Health check
# ------------------------------------------------–
echo "Test Suite: Health Check"
assert_http_status "Server responds to requests" "200" "$API_BASE/"
echo ""

# --------------------------------------------------
# Test 2: Create a server instance
# ------------------------------------------------–
echo "Test Suite: Create Server Instance"

CREATE_RESPONSE=$(curl -s -X POST "$API_BASE/api/servers" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "Test Nullius Server",
        "saveFile": "1780434878_5895/game_save.zip"
    }')

echo "Create response: $CREATE_RESPONSE"

SERVER_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id' 2>/dev/null)
if [ -z "$SERVER_ID" ] || [ "$SERVER_ID" = "null" ]; then
    echo -e "  ${RED}✗${NC} Failed to extract server ID from response"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "  ${GREEN}✓${NC} Server created with ID: $SERVER_ID"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    track_server_id "$SERVER_ID"
fi

echo ""

# --------------------------------------------------
# Test 3: Verify mod extraction from save
# ------------------------------------------------–
echo "Test Suite: Mod Extraction"

# Update the server config with the save file path
UPDATE_RESPONSE=$(curl -s -X PUT "$API_BASE/api/servers/$SERVER_ID/config" \
    -H "Content-Type: application/json" \
    -d "{
        \"saveFile\": \"1780434878_5895/game_save.zip\",
        \"name\": \"Test Nullius Server\"
    }")

# Get the server config to verify mods were extracted
CONFIG_RESPONSE=$(curl -s "$API_BASE/api/servers/$SERVER_ID/config")
echo "Server config: $CONFIG_RESPONSE"

MOD_COUNT=$(echo "$CONFIG_RESPONSE" | jq '.mods | length' 2>/dev/null)
echo "Mod count: $MOD_COUNT"

if [ "$MOD_COUNT" != "null" ] && [ "$MOD_COUNT" -gt 0 ] 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Mods extracted from save (count: $MOD_COUNT)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
    
    # Verify specific mods from Nullius pack
    if echo "$CONFIG_RESPONSE" | jq -r '.mods[].name' 2>/dev/null | grep -q "base"; then
        echo -e "  ${GREEN}✓${NC} Base mod found in extracted mods"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Base mod not found (may be optional)"
    fi
    
    if echo "$CONFIG_RESPONSE" | jq -r '.mods[].name' 2>/dev/null | grep -q "nullius"; then
        echo -e "  ${GREEN}✓${NC} Nullius mod found in extracted mods"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Nullius mod not found (expected in save)"
    fi
else
    echo -e "  ${RED}✗${NC} No mods extracted from save file"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""

# ------------------------------------------------–
# Test 4: List servers
# ------------------------------------------------–
echo "Test Suite: List Servers"

LIST_RESPONSE=$(curl -s "$API_BASE/api/servers")
echo "List response: $LIST_RESPONSE"

SERVER_COUNT=$(echo "$LIST_RESPONSE" | jq 'length' 2>/dev/null)
if [ "$SERVER_COUNT" != "null" ] && [ "$SERVER_COUNT" -ge 1 ] 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Servers list contains at least 1 server (count: $SERVER_COUNT)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} Failed to list servers"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""

# ------------------------------------------------–
# Test 5: Start the server (with polling wait loop)
# ------------------------------------------------–
echo "Test Suite: Start Server"

echo -e "${YELLOW}Attempting to start server (this may take time for mod downloads)...${NC}"
START_RESPONSE=$(curl -s -X POST "$API_BASE/api/servers/$SERVER_ID/start")
echo "Start response: $START_RESPONSE"

if echo "$START_RESPONSE" | grep -q '"status"'; then
    echo -e "  ${GREEN}✓${NC} Server start command accepted"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} Server start failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Poll for server to actually reach running state (up to 60s)
echo -e "${YELLOW}Polling for server to reach running state (timeout 60s)...${NC}"
MAX_WAIT=60
WAITED=0
SERVER_RUNNING=false

while [ $WAITED -lt $MAX_WAIT ]; do
    sleep 3
    WAITED=$((WAITED + 3))

    LIST_RESP=$(curl -s "$API_BASE/api/servers")
    RUNNING=$(echo "$LIST_RESP" | jq --arg id "$SERVER_ID" '[.[] | select(.id == $id)][0].running' 2>/dev/null)
    START_FAILED=$(echo "$LIST_RESP" | jq --arg id "$SERVER_ID" '[.[] | select(.id == $id)][0].startFailed' 2>/dev/null)
    FAIL_MSG=$(echo "$LIST_RESP" | jq --arg id "$SERVER_ID" -r '[.[] | select(.id == $id)][0].startFailMessage' 2>/dev/null)

    if [ "$START_FAILED" = "true" ]; then
        echo -e "  ${RED}✗${NC} Server start failed: $FAIL_MSG"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        break
    fi

    if [ "$RUNNING" = "true" ]; then
        SERVER_RUNNING=true
        echo -e "  ${GREEN}✓${NC} Server is running (after ${WAITED}s)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        break
    fi

    echo -e "  ${YELLOW}⏳${NC} Still starting... (${WAITED}s elapsed)"
done

if [ "$SERVER_RUNNING" = "false" ] && [ "$WAITED" -ge $MAX_WAIT ]; then
    echo -e "  ${RED}✗${NC} Server did not start within ${MAX_WAIT}s timeout"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""

# ------------------------------------------------–
# Test 6: Server Logs
# ------------------------------------------------–
echo "Test Suite: Server Logs"

# Factorio may take several seconds to create and write to its --console-log file.
# Poll with retries to handle the timing reliably.
LOGS_RESPONSE=""
LOG_MAX_WAIT=20
LOG_WAITED=0

while [ $LOG_WAITED -lt $LOG_MAX_WAIT ]; do
    sleep 3
    LOG_WAITED=$((LOG_WAITED + 3))
    LOGS_RESPONSE=$(curl -s "$API_BASE/api/servers/$SERVER_ID/logs")
    if [ -n "$LOGS_RESPONSE" ] && [ "$LOGS_RESPONSE" != "[]" ]; then
        break
    fi
    echo -e "  ${YELLOW}⏳${NC} Waiting for log file... (${LOG_WAITED}s)"
done

if [ -n "$LOGS_RESPONSE" ] && [ "$LOGS_RESPONSE" != "[]" ]; then
    LOG_LINES=$(echo "$LOGS_RESPONSE" | jq 'length' 2>/dev/null)
    echo -e "  ${GREEN}✓${NC} Retrieved $LOG_LINES log lines from server (after ${LOG_WAITED}s)"
    TESTS_PASSED=$((TESTS_PASSED + 1))

    # Verify logs contain expected content
    if echo "$LOGS_RESPONSE" | grep -qi "factorio\|log\|version\|server" 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Logs contain expected Factorio content"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${YELLOW}⚠${NC} Logs retrieved but content doesn't match expected patterns"
        echo "Log sample: $(echo "$LOGS_RESPONSE" | jq -r '.[0]' 2>/dev/null)"
    fi
else
    echo -e "  ${RED}✗${NC} Failed to retrieve server logs (empty response after ${LOG_WAITED}s)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""

# ------------------------------------------------–
# Test 7: Duplicate server prevention
# ------------------------------------------------–
echo "Test Suite: Duplicate Server Prevention"

BEFORE_COUNT=$(curl -s "$API_BASE/api/servers" | jq 'length' 2>/dev/null)

CREATE_2=$(curl -s -X POST "$API_BASE/api/servers" \
    -H "Content-Type: application/json" \
    -d '{"name":"Duplicate Test","saveFile":""}')
ID_2=$(echo "$CREATE_2" | jq -r '.id' 2>/dev/null)

CREATE_3=$(curl -s -X POST "$API_BASE/api/servers" \
    -H "Content-Type: application/json" \
    -d '{"name":"Duplicate Test 2","saveFile":""}')
ID_3=$(echo "$CREATE_3" | jq -r '.id' 2>/dev/null)

AFTER_COUNT=$(curl -s "$API_BASE/api/servers" | jq 'length' 2>/dev/null)

if [ "$ID_2" != "$ID_3" ] && [ "$ID_2" != "$SERVER_ID" ] && [ "$ID_3" != "$SERVER_ID" ]; then
    echo -e "  ${GREEN}✓${NC} Each create generates a unique server ID"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} Duplicate IDs detected (ID_2=$ID_2, ID_3=$ID_3)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

if [ "$AFTER_COUNT" = "$((BEFORE_COUNT + 2))" ]; then
    echo -e "  ${GREEN}✓${NC} Server count increased exactly by 2 (no phantom instances)"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} Server count mismatch (before=$BEFORE_COUNT, after=$AFTER_COUNT, expected $((BEFORE_COUNT + 2)))"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Clean up the extra servers
if [ -n "$ID_2" ] && [ "$ID_2" != "null" ]; then
    curl -s -X DELETE "$API_BASE/api/servers/$ID_2" > /dev/null 2>&1
fi
if [ -n "$ID_3" ] && [ "$ID_3" != "null" ]; then
    curl -s -X DELETE "$API_BASE/api/servers/$ID_3" > /dev/null 2>&1
fi

echo ""

# ------------------------------------------------–
# Test 8: Delete server instance
# ------------------------------------------------–
echo "Test Suite: Delete Server Instance"

# Stop first if running
curl -s -X POST "$API_BASE/api/servers/$SERVER_ID/stop" > /dev/null 2>&1
sleep 2

DELETE_RESPONSE=$(curl -s -X DELETE "$API_BASE/api/servers/$SERVER_ID")
assert_http_status "Delete server returns 204" "204" "$API_BASE/api/servers/$SERVER_ID" "DELETE"

# Verify deletion
VERIFY_DELETE=$(curl -s "$API_BASE/api/servers/$SERVER_ID/config")
if echo "$VERIFY_DELETE" | grep -q '"error"'; then
    echo -e "  ${GREEN}✓${NC} Server instance deleted successfully"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "  ${RED}✗${NC} Server instance still exists after deletion"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""

# ------------------------------------------------–
# Summary
# ------------------------------------------------–
echo "============================================"
echo "Test Summary"
echo "============================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed${NC}"
    exit 1
fi
