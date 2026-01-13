#!/bin/bash
# Test script for syslm-socket and syslm-cli

set -e

echo "=== Testing syslm RPC Transport ==="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    ((PASS++))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    ((FAIL++))
}

# Build
echo "Building..."
swift build -q

# Check if socket server is running
SOCKET_PATH="/tmp/syslm-test.sock"

# Start socket server
echo "Starting socket server..."
rm -f "$SOCKET_PATH"
swift run syslm-socket --socket "$SOCKET_PATH" &>/dev/null &
SOCKET_PID=$!
sleep 2

# Verify socket exists
if [ -S "$SOCKET_PATH" ]; then
    pass "Socket server started"
else
    fail "Socket server failed to start"
    exit 1
fi

# Test 1: CLI direct mode
echo ""
echo "Test 1: CLI direct mode"
RESULT=$(swift run syslm-cli "Say only the word 'hello'" 2>&1)
if echo "$RESULT" | grep -qi "hello"; then
    pass "Direct mode response contains 'hello'"
else
    fail "Direct mode did not return expected response: $RESULT"
fi

# Test 2: CLI socket mode
echo ""
echo "Test 2: CLI socket mode"
RESULT=$(swift run syslm-cli --socket "$SOCKET_PATH" "Say only the word 'world'" 2>&1)
if echo "$RESULT" | grep -qi "world"; then
    pass "Socket mode response contains 'world'"
else
    fail "Socket mode did not return expected response: $RESULT"
fi

# Test 3: CLI streaming mode
echo ""
echo "Test 3: CLI streaming mode (direct)"
RESULT=$(swift run syslm-cli -s "Count from 1 to 3" 2>&1)
if echo "$RESULT" | grep -q "1" && echo "$RESULT" | grep -q "2"; then
    pass "Streaming mode works"
else
    fail "Streaming mode did not return expected response: $RESULT"
fi

# Test 4: CLI with system message
echo ""
echo "Test 4: CLI with system message"
RESULT=$(swift run syslm-cli --system "You only respond with 'ARRR'" "Hello" 2>&1)
if echo "$RESULT" | grep -qi "arr"; then
    pass "System message works"
else
    fail "System message did not affect response: $RESULT"
fi

# Test 5: CLI stdin mode
echo ""
echo "Test 5: CLI stdin mode"
RESULT=$(echo "Say 'stdin works'" | swift run syslm-cli 2>&1)
if echo "$RESULT" | grep -qi "stdin"; then
    pass "Stdin mode works"
else
    fail "Stdin mode did not return expected response: $RESULT"
fi

# Test 6: CLI help
echo ""
echo "Test 6: CLI help"
RESULT=$(swift run syslm-cli --help 2>&1)
if echo "$RESULT" | grep -q "USAGE"; then
    pass "Help command works"
else
    fail "Help command did not show usage: $RESULT"
fi

# Cleanup
echo ""
echo "Cleaning up..."
kill $SOCKET_PID 2>/dev/null || true
rm -f "$SOCKET_PATH"

# Summary
echo ""
echo "=== Results ==="
echo -e "Passed: ${GREEN}$PASS${NC}"
echo -e "Failed: ${RED}$FAIL${NC}"

if [ $FAIL -gt 0 ]; then
    exit 1
fi
