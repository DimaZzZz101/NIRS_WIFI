#!/bin/bash
#
# find_password.sh - Конвертация pcapng в hc22000 и подбор пароля с hashcat
#
# Использование: $0 <pcapng_path>
# Пример:
#   $0 wifi_data/handshakes/20251214_123456_handshake.pcapng
#   $0 wifi_data/pmkid/20251215_065837_pmkid.pcapng

set -euo pipefail

# Функция для очистки: убивает контейнер, если он запущен
cleanup() {
    if [ -n "${CONTAINER_NAME:-}" ]; then
        echo "Stopping container: $CONTAINER_NAME" >&2
        docker kill "$CONTAINER_NAME" 2>/dev/null || true
    fi
    exit 1
}

# Ловим сигналы SIGINT и SIGTERM
trap cleanup SIGINT SIGTERM

if [ $# -ne 1 ]; then
    SCRIPT_NAME="$(basename "$0")"
    cat >&2 << EOF
Usage: $SCRIPT_NAME <pcapng_path>
EOF
    exit 1
fi

PCAPNG_PATH="$1"

# Проверка, что путь не содержит небезопасные элементы
if [[ "$PCAPNG_PATH" =~ \.\./ ]]; then
    echo "ERROR: Path contains unsafe elements: $PCAPNG_PATH" >&2
    exit 1
fi

DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
WORDLIST_PATH="./wordlists/wordlist.txt"

if [ ! -f "$PCAPNG_PATH" ]; then
    echo "ERROR: Input file not found: $PCAPNG_PATH" >&2
    exit 1
fi

PCAPNG_DIR=$(dirname "$PCAPNG_PATH")
PCAPNG_FILE=$(basename "$PCAPNG_PATH")

if [[ "$PCAPNG_DIR" == *"/handshakes" ]]; then
    TYPE="handshake"
elif [[ "$PCAPNG_DIR" == *"/pmkid" ]]; then
    TYPE="pmkid"
else
    echo "ERROR: Input file must be in wifi_data/handshakes/ or wifi_data/pmkid/" >&2
    exit 1
fi

if [[ "$PCAPNG_FILE" =~ ^([0-9]{8}_[0-9]{6})_${TYPE}\.pcapng$ ]]; then
    TIMESTAMP="${BASH_REMATCH[1]}"
else
    echo "ERROR: Invalid filename format: $PCAPNG_FILE" >&2
    exit 1
fi

HASH_FILE="$PCAPNG_DIR/${TIMESTAMP}_${TYPE}_hash.hc22000"
PASS_FILE_TEMP="$PCAPNG_DIR/${TIMESTAMP}_${TYPE}_pass.txt"  # Временный

if [ ! -f "$WORDLIST_PATH" ]; then
    echo "ERROR: Wordlist not found: $WORDLIST_PATH" >&2
    exit 1
fi

echo "Processing $TYPE file: $PCAPNG_PATH" >&2
echo "Timestamp: $TIMESTAMP" >&2

# Конвертация в hc22000
echo "Converting to hc22000 format..." >&2
docker run --rm \
    -v "$(pwd)/$DATA_DIR:/$DATA_DIR" \
    "$DOCKER_IMAGE" \
    hcxpcapngtool -o "/$HASH_FILE" "/$PCAPNG_PATH"

if [ ! -f "$HASH_FILE" ] || [ ! -s "$HASH_FILE" ]; then
    echo "ERROR: No valid hashes extracted (empty .hc22000)" >&2
    exit 1
fi

# Извлечение ESSID и BSSID из первой строки .hc22000
echo "Extracting ESSID and BSSID from hash..." >&2
FIRST_LINE=$(head -1 "$HASH_FILE")

# Парсинг: MAC_AP MAC_STA ESSID_HEX
IFS='*' read -ra FIELDS <<< "$FIRST_LINE"
if [ ${#FIELDS[@]} -lt 6 ]; then
    echo "ERROR: Could not parse hash line (too few fields)" >&2
    exit 1
fi

MAC_AP="${FIELDS[3]}"
MAC_STA="${FIELDS[4]}"
ESSID_HEX="${FIELDS[5]}"

if [ -z "$MAC_AP" ] || [ -z "$ESSID_HEX" ]; then
    echo "ERROR: Could not parse hash line" >&2
    exit 1
fi

ESSID=$(echo "$ESSID_HEX" | xxd -r -p)
BSSID_FORMATTED=$(echo "$MAC_AP" | sed 's/../\U&:/g' | sed 's/:$//')

PASS_FILE="$PCAPNG_DIR/${TIMESTAMP}_${ESSID}_${BSSID_FORMATTED}_pass.txt"

echo "Extracted ESSID: $ESSID" >&2
echo "Extracted BSSID: $BSSID_FORMATTED" >&2

# Подбор пароля
echo "Cracking with hashcat -m 22000..." >&2
docker run --rm \
    -v "$(pwd)/$DATA_DIR:/$DATA_DIR" \
    -v "$(pwd)/wordlists:/wordlists:ro" \
    "$DOCKER_IMAGE" \
    hashcat -m 22000 "/$HASH_FILE" /wordlists/wordlist.txt -o "/$PASS_FILE_TEMP" --force

# Переименовываем временный файл
if [ -f "$PASS_FILE_TEMP" ] && [ -s "$PASS_FILE_TEMP" ]; then
    mv "$PASS_FILE_TEMP" "$PASS_FILE"
    echo "PASSWORD FOUND!" >&2
    echo "Saved to: $PASS_FILE" >&2
    cat "$PASS_FILE" >&2
else
    rm -f "$PASS_FILE_TEMP"
    echo "No password found in wordlist" >&2
fi

echo "Process completed" >&2