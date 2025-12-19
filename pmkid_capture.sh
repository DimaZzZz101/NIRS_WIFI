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

# Проверка аргументов
if [ $# -ne 2 ]; then
    SCRIPT_NAME="$(basename "$0")"
    cat >&2 << EOF
Usage: $SCRIPT_NAME <interface> <timeout_seconds>

EOF
    exit 1
fi

INTERFACE="$1"
TIMEOUT="$2"

# Проверка имени интерфейса
if [[ ! "$INTERFACE" =~ ^[a-zA-Z0-9]+([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
    echo "ERROR: Interface name contains invalid characters" >&2
    exit 1
fi

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
        "$DOCKER_IMAGE" ip link show "$1" >/dev/null 2>&1
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

# Уникальное имя контейнера
CONTAINER_NAME="hcxdump-${TIMESTAMP}"

# Запуск hcxdumptool в фоне
docker run --rm -d \
    --name "$CONTAINER_NAME" \
    --net=host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_MODULE \
    --cpus="1" \
    --memory="512m" \
    -v "$(pwd)/$DATA_DIR/pmkid:/$DATA_DIR/pmkid" \
    "$DOCKER_IMAGE" \
    timeout --signal=INT ${TIMEOUT}s hcxdumptool -i "$INTERFACE" -w "/$OUTPUT_FILE" --disable_disassociation > /dev/null 2>&1

# Ждём завершения или убиваем
(
    sleep "$TIMEOUT"
    docker kill "$CONTAINER_NAME" 2>/dev/null || true
) &

# Ждём завершения контейнера
docker wait "$CONTAINER_NAME" 2>/dev/null || true

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