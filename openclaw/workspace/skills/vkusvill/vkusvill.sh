#!/bin/bash
# VkusVill MCP wrapper
# Usage: vkusvill.sh <action> [args...]
#   search <query> [page] [sort]
#   details <product_id>
#   check <product_id_or_url>
#   cart <json_products>

set -euo pipefail

MCP_URL="https://mcp001.vkusvill.ru/mcp"

init_session() {
  local resp
  resp=$(curl -s -i -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"openclaw-vkusvill","version":"1.0"}}}')
  SESSION_ID=$(echo "$resp" | grep -i 'mcp-session-id' | awk '{print $2}' | tr -d '\r')
  curl -s -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' > /dev/null
}

call_tool() {
  local tool_name="$1"
  local args="$2"
  curl -s -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":$args}}"
}

ACTION="${1:-help}"
shift || true

case "$ACTION" in
  check)
    INPUT="${1:-}"
    if [ -z "$INPUT" ]; then
      echo "NOT_AVAILABLE|error|Укажите ID товара или URL"
      exit 1
    fi
    # If input is just a number, convert to xmlid URL
    if [[ "$INPUT" =~ ^[0-9]+$ ]]; then
      PRODUCT_URL="https://vkusvill.ru/goods/xmlid/$INPUT"
    else
      PRODUCT_URL="$INPUT"
    fi
    CHECK_RESULT=$(curl -s --max-time 45 "http://host.docker.internal:18790/check?url=${PRODUCT_URL}" 2>/dev/null)
    if [ -z "$CHECK_RESULT" ]; then
      echo "NOT_AVAILABLE|error|Сервис проверки наличия недоступен"
      exit 1
    fi
    echo "$CHECK_RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('status', 'unknown')
q = d.get('quantity', 0)
t = d.get('text', '')
n = d.get('productName', '')
a = d.get('addressText', '')
if s == 'available':
    print(f'AVAILABLE|{q}|{n}: {t} (адрес: {a})')
elif s == 'not_available':
    print(f'NOT_AVAILABLE|0|{n}: {t} (адрес: {a})')
else:
    print(f'NOT_AVAILABLE|unknown|{n}: не удалось определить наличие')
"
    ;;
  *)
    init_session
    case "$ACTION" in
      search)
        QUERY="${1:-}"
        PAGE="${2:-1}"
        SORT="${3:-popularity}"
        call_tool "vkusvill_products_search" "{\"q\":\"$QUERY\",\"page\":$PAGE,\"sort\":\"$SORT\"}"
        ;;
      details)
        ID="${1:-}"
        call_tool "vkusvill_product_details" "{\"id\":$ID}"
        ;;
      cart)
        PRODUCTS="${1:-[]}"
        call_tool "vkusvill_cart_link_create" "{\"products\":$PRODUCTS}"
        ;;
      *)
        echo "Usage: vkusvill.sh <search|details|check|cart> [args...]"
        echo "  search <query> [page] [sort]  - Search products"
        echo "  details <product_id>          - Get product details (KBJU)"
        echo "  check <id_or_url>             - Check availability by delivery address"
        echo "  cart '<json_products>'         - Create cart link"
        exit 1
        ;;
    esac
    ;;
esac
