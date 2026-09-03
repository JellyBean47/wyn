#!/bin/bash
# Drive `wyn mcp` the way a real MCP client does: JSON-RPC on stdin, one line
# per message, responses on stdout. Nothing here is a mock.
set -euo pipefail
WYN="${1:-$HOME/Desktop/wyn/.build/release/wyn}"

{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_installed_games","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_launch_evidence","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"save_profile","arguments":{"profile":{"id":"smoke-refused","name":"Refused","exePatterns":["x.exe"],"environment":{"MTL_HUD_ENABLED":"1"}}}}}'
} | "$WYN" mcp 2>/dev/null
