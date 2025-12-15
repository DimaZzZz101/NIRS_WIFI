#!/bin/bash
#
# pmkid_capture.sh - Захват PMKID с помощью hcxdumptool (channel hopping)
#
# Использование: $0 <interface> <timeout_seconds>
# Пример:
#   $0 wlan0mon 120     # Ловить PMKID в течение 120 секунд
#
# Выходной файл: wifi_data/pmkid/<timestamp>_pmkid.pcapng

set -euo pipefail

# Проверка аргументов
if [ $# -ne 2 ]; then
    echo "Usage: $0 <interface> <timeout_seconds>" >&2
    echo "Example: $0 wlan0mon 120" >&2
    exit 1
fi

INTERFACE="$1"
TIMEOUT="$2"

# Проверка, что timeout - число
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Timeout must be a positive integer" >&2
    exit 1
fi

# Параметры
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
PMKID_DIR="$DATA_DIR/pmkid"

# Функция проверки интерфейса
check_interface_exists() {
    docker run --rm --net=host --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        $DOCKER_IMAGE ip link show "$1" >/dev/null 2>&1
    return $?
}

if ! check_interface_exists "$INTERFACE"; then
    echo "ERROR: Interface '$INTERFACE' not found or not accessible" >&2
    exit 1
fi

# Создаём директорию
mkdir -p "$PMKID_DIR"

# Генерируем timestamp и путь к файлу
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTPUT_FILE="$PMKID_DIR/${TIMESTAMP}_pmkid.pcapng"

echo "Starting PMKID capture (channel hopping) for $TIMEOUT seconds" >&2
echo "Interface: $INTERFACE" >&2
echo "Output:    $OUTPUT_FILE" >&2

# Команда hcxdumptool
HCX_CMD="hcxdumptool -i $INTERFACE -w /$OUTPUT_FILE"

# Оборачиваем в timeout
HCX_CMD="timeout --signal=INT ${TIMEOUT}s $HCX_CMD"

# Запуск в Docker с подавлением лишнего вывода
docker run --rm \
    --name "hcxdump-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_MODULE \
    --cpus="1" \
    --memory="512m" \
    -v "$(pwd)/$DATA_DIR/pmkid:/$DATA_DIR/pmkid" \
    $DOCKER_IMAGE \
    bash -c "$HCX_CMD" > /dev/null 2> >(grep -v -E "BPF is unset|experimental penetration testing tool|mercilessly|irreparable damage|Not understanding|starting...|exit on sigterm" >&2)

# Проверка результата
if [ -f "$OUTPUT_FILE" ]; then
    if [ -s "$OUTPUT_FILE" ]; then
        SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
        echo "PMKID capture completed successfully!" >&2
        echo "File saved: $OUTPUT_FILE (size: $SIZE)" >&2
        echo "" >&2
    else
        echo "WARNING: Output file is empty (no packets captured)" >&2
        rm -f "$OUTPUT_FILE"
    fi
else
    echo "ERROR: Output file was not created" >&2
    exit 1
fi