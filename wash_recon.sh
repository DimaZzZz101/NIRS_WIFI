#!/bin/bash
#
# wash-scan.sh - Запуск wash для извлечения WPS-информации из .cap или live-сканирования
#
# Использование: $0 [-f <cap_file>] [-i <interface>] [options]
# Примеры:
#   $0 -f path/to/capture-01.cap      # Анализ существующего .cap от airodump
#   $0 -i wlan0mon                    # Live-сканирование на интерфейсе
#   $0 -f path/to/capture-01.cap -c 6 # Анализ .cap с фокусом на канал 6
#   $0 -i wlan0mon -2                 # Live-сканирование только 2.4 GHz
#
# Опции:
#   -f <cap_file>        Путь к .cap-файлу для анализа (приоритет над -i)
#   -i <interface>       Интерфейс для live-сканирования (если нет -f)
#   -c <channel>         Канал для фокуса (для live-режима)
#   -2                   Использовать 2.4 GHz
#   -5                   Использовать 5 GHz
#   -a                   Показать все AP, даже без WPS
#   -j                   Вывод в JSON (по умолчанию включено)
#   -w <prefix>          Префикс для выходного файла (опционально)
#
# Выходной файл: wifi_data/recon/<timestamp>-wps.json (или с префиксом)

set -euo pipefail

# Проверка минимальных аргументов
if [ $# -lt 1 ]; then
    echo "Usage: $0 [-f <cap_file>] [-i <interface>] [options]" >&2
    echo "At least one of -f or -i is required." >&2
    exit 1
fi

# Параметры по умолчанию
CAP_FILE=""
INTERFACE=""
CHANNEL=""
BAND_2GHZ=""
BAND_5GHZ=""
SHOW_ALL=""
USE_JSON="--json"  # По умолчанию JSON
FILE_PREFIX=""
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
RECON_DIR="$DATA_DIR/recon"

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        -f)
            CAP_FILE="$2"
            if [ ! -f "$CAP_FILE" ]; then
                echo "ERROR: .cap file '$CAP_FILE' not found" >&2
                exit 1
            fi
            shift 2
            ;;
        -i)
            INTERFACE="$2"
            shift 2
            ;;
        -c)
            CHANNEL="$2"
            if ! [[ "$CHANNEL" =~ ^[0-9]+$ ]]; then
                echo "ERROR: Channel must be a number" >&2
                exit 1
            fi
            shift 2
            ;;
        -2)
            BAND_2GHZ="--2ghz"
            shift
            ;;
        -5)
            BAND_5GHZ="--5ghz"
            shift
            ;;
        -a)
            SHOW_ALL="--all"
            shift
            ;;
        -j)
            USE_JSON="--json"
            shift
            ;;
        -w)
            FILE_PREFIX="$2"
            FILE_PREFIX=$(echo "$FILE_PREFIX" | tr -cd '[:alnum:]_-')
            shift 2
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Проверка: должен быть либо -f, либо -i
if [ -z "$CAP_FILE" ] && [ -z "$INTERFACE" ]; then
    echo "ERROR: Must specify either -f <cap_file> or -i <interface>" >&2
    exit 1
fi

# Если -f указан, игнорируем -i
if [ -n "$CAP_FILE" ]; then
    INTERFACE=""  # Не используем интерфейс
fi

# Создание директории
mkdir -p "$RECON_DIR"

# Генерация имени файла
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
if [ -z "$FILE_PREFIX" ]; then
    OUTPUT_FILE="$RECON_DIR/${TIMESTAMP}-wps.json"
else
    OUTPUT_FILE="$RECON_DIR/${TIMESTAMP}-${FILE_PREFIX}-wps.json"
fi

# Формирование команды wash
WASH_CMD="wash $USE_JSON $SHOW_ALL"

if [ -n "$CAP_FILE" ]; then
    WASH_CMD="$WASH_CMD -f $CAP_FILE"
else
    WASH_CMD="$WASH_CMD -i $INTERFACE"
fi

if [ -n "$CHANNEL" ]; then
    WASH_CMD="$WASH_CMD -c $CHANNEL"
fi

if [ -n "$BAND_2GHZ" ]; then
    WASH_CMD="$WASH_CMD $BAND_2GHZ"
fi

if [ -n "$BAND_5GHZ" ]; then
    WASH_CMD="$WASH_CMD $BAND_5GHZ"
fi

echo "Running wash with command:" >&2
echo "  $WASH_CMD" >&2

# Запуск в Docker (аналогично твоему скрипту)
docker run --rm \
    --name "wash-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cpus="0.5" \
    --memory="1g" \
    -v "$(pwd)/$DATA_DIR/recon:/$DATA_DIR/recon" \
    $DOCKER_IMAGE \
    $WASH_CMD > "$OUTPUT_FILE" 2>/dev/null

# Проверка выхода
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    echo "$OUTPUT_FILE"  # Вывод пути к JSON для дальнейшей обработки
    echo "Created file: $(basename "$OUTPUT_FILE")" >&2
else
    echo "ERROR: No output JSON file created or empty" >&2
    exit 1
fi