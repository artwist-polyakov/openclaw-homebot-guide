#!/bin/bash
# Проверка наличия товара ВкусВилл по адресу доставки
# Использование: ./vv_check_availability.sh <URL_товара>
# Возвращает: AVAILABLE|кол-во|описание или NOT_AVAILABLE|0|описание

URL="$1"
if [ -z "$URL" ]; then
    echo "NOT_AVAILABLE|error|Укажите URL товара"
    exit 1
fi

RESULT=$(curl -s --max-time 45 "http://host.docker.internal:18790/check?url=${URL}" 2>/dev/null)

if [ -z "$RESULT" ]; then
    echo "NOT_AVAILABLE|error|Сервис проверки наличия недоступен"
    exit 1
fi

STATUS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null)
QTY=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('quantity',0))" 2>/dev/null)
TEXT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('text',''))" 2>/dev/null)
NAME=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('productName',''))" 2>/dev/null)
ADDR=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('addressText',''))" 2>/dev/null)

case "$STATUS" in
    available)     echo "AVAILABLE|${QTY}|${NAME}: ${TEXT} (адрес: ${ADDR})" ;;
    not_available) echo "NOT_AVAILABLE|0|${NAME}: ${TEXT} (адрес: ${ADDR})" ;;
    *)             echo "NOT_AVAILABLE|unknown|${NAME}: не удалось определить наличие" ;;
esac
