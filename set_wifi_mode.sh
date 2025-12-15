#!/bin/bash
#
# set_wifi_mode.sh - Управление режимом монитора Wi-Fi интерфейсов
#
# Этот скрипт активирует/деактивирует режим монитора для Wi-Fi интерфейсов
# с использованием airmon-ng внутри Docker-контейнера.
#
# Вход: имя_интерфейса, действие (start|stop)
# Выход (stdout): Имя результирующего интерфейса после операции
# Коды завершения: 0=успех, 1=ошибка

set -euo pipefail

# Параметры скрипта
INTERFACE="$1"              # Исходный интерфейс (например, wlan0 или wlan0mon)
ACTION="$2"                 # Действие: start (активация) или stop (деактивация)
DOCKER_IMAGE="wifi:latest"  # Docker-образ с необходимыми утилитами
DOCKER_OPTS="--rm --net=host --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW"

# Базовая проверка аргументов
if [ $# -ne 2 ]; then
    echo "Error: Invalid arguments" >&2
    echo "Usage: $0 <interface> <start|stop>" >&2
    exit 1
fi

# Проверка допустимости действия
if [ "$ACTION" != "start" ] && [ "$ACTION" != "stop" ]; then
    echo "Error: Action must be 'start' or 'stop'" >&2
    exit 1
fi

# Функция проверки существования интерфейса
check_interface() {
    docker run $DOCKER_OPTS $DOCKER_IMAGE ip link show "$1" >/dev/null 2>&1
    return $?
}

# Проверка существования входного интерфейса
if ! check_interface "$INTERFACE"; then
    echo "Error: Interface '$INTERFACE' not found" >&2
    exit 1
fi

# Валидация имени интерфейса в зависимости от действия
if [ "$ACTION" = "start" ]; then
    # Для активации: интерфейс не должен быть в режиме монитора (оканчиваться на mon)
    if [[ "$INTERFACE" =~ mon$ ]]; then
        echo "Error: Interface '$INTERFACE' appears to be in monitor mode already" >&2
        exit 1
    fi
    EXPECTED_RESULT="${INTERFACE}mon"  # Ожидаемый результат: wlan0 -> wlan0mon
else
    # Для деактивации: интерфейс должен быть в режиме монитора (оканчиваться на mon)
    if [[ ! "$INTERFACE" =~ mon$ ]]; then
        echo "Error: Interface '$INTERFACE' doesn't appear to be in monitor mode" >&2
        exit 1
    fi
    EXPECTED_RESULT="${INTERFACE%mon}"  # Ожидаемый результат: wlan0mon -> wlan0
fi

# Проверка существования целевого интерфейса (для предотвращения конфликтов)
if check_interface "$EXPECTED_RESULT"; then
    if [ "$ACTION" = "start" ]; then
        # Для активации: целевой интерфейс монитора не должен существовать
        echo "Error: Target interface '$EXPECTED_RESULT' already exists" >&2
        exit 1
    fi
fi

# Используем airmon-ng для изменения режима
if ! docker run $DOCKER_OPTS --cap-add=SYS_MODULE -v /dev/bus/usb:/dev/bus/usb \
    --name "airmon-ng-${ACTION}-${INTERFACE}" \
    $DOCKER_IMAGE \
    airmon-ng "$ACTION" "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: airmon-ng execution failed" >&2
    exit 1
fi

# Верификация результата и вывод имени интерфейса
if [ "$ACTION" = "start" ]; then
    # Поиск реального интерфейса в режиме монитора
    # Используем iw для точного определения интерфейсов с типом "monitor"
    DETECTED_MON=$(docker run $DOCKER_OPTS $DOCKER_IMAGE \
        sh -c "iw dev 2>/dev/null | grep -A1 'Interface' | grep -B1 'type monitor' | grep 'Interface' | awk '{print \$2}' | head -1")
    
    if [ -n "$DETECTED_MON" ]; then
        echo "$DETECTED_MON"  # Выводим обнаруженный интерфейс монитора
    elif check_interface "$EXPECTED_RESULT"; then
        echo "$EXPECTED_RESULT"  # Выводим ожидаемый интерфейс монитора
    else
        echo "Error: Failed to detect monitor interface after activation" >&2
        exit 1
    fi
else
    # Для деактивации проверяем, что управляемый интерфейс создан
    if check_interface "$EXPECTED_RESULT"; then
        echo "$EXPECTED_RESULT"  # Выводим имя управляемого интерфейса
    else
        echo "Error: Failed to detect managed interface after deactivation" >&2
        exit 1
    fi
fi