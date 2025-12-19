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

# Валидация аргументов
if [ $# -ne 2 ]; then
    echo "Usage: $0 <interface> <start|stop>" >&2

    exit 1
fi

# Теперь можно безопасно использовать $1 и $2
INTERFACE="$1"              # Исходный интерфейс (например, wlan0 или wlan0mon)
ACTION="$2"                 # Действие: start (активация) или stop (деактивация)
DOCKER_IMAGE="wifi:latest"  # Docker-образ с необходимыми утилитами
DOCKER_BASE_OPTS=(
    --rm
    --net=host
    --cap-drop=ALL
    --cap-add=NET_ADMIN
    --cap-add=NET_RAW
)

# Проверка допустимости действия
if [ "$ACTION" != "start" ] && [ "$ACTION" != "stop" ]; then
    echo "Error: Action must be 'start' or 'stop'" >&2
    exit 1
fi

# Проверка имени интерфейса на безопасность
if [[ ! "$INTERFACE" =~ ^[a-zA-Z0-9]+([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
    echo "Error: Interface name contains invalid characters" >&2
    exit 1
fi

# Функция проверки существования интерфейса
check_interface() {
    local iface="$1"
    docker run "${DOCKER_BASE_OPTS[@]}" "$DOCKER_IMAGE" ip link show "$iface" >/dev/null 2>&1
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
        echo "Error: Target interface '$EXPECTED_RESULT' already exists" >&2
        exit 1
    fi
fi

# Запуск airmon-ng с расширенными капабилити
if ! docker run "${DOCKER_BASE_OPTS[@]}" --cap-add=SYS_MODULE -v /dev/bus/usb:/dev/bus/usb \
    --name "airmon-ng-${ACTION}-${INTERFACE//\//-}" \
    "$DOCKER_IMAGE" \
    airmon-ng "$ACTION" "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: airmon-ng execution failed" >&2
    exit 1
fi

# Ожидание появления/исчезновения интерфейса
wait_for_interface() {
    local target="$1"
    local should_exist="$2"
    local timeout=10
    for ((i = 0; i < timeout; i++)); do
        if check_interface "$target"; then
            [[ "$should_exist" == "true" ]] && return 0
        else
            [[ "$should_exist" == "false" ]] && return 0
        fi
        sleep 1
    done
    return 1
}

# Верификация результата и вывод имени интерфейса
if [ "$ACTION" = "start" ]; then
    # Ждём появления интерфейса монитора
    if wait_for_interface "$EXPECTED_RESULT" true; then
        echo "$EXPECTED_RESULT"
    else
        # Альтернативный поиск через iw
        DETECTED_MON=$(docker run "${DOCKER_BASE_OPTS[@]}" "$DOCKER_IMAGE" \
            sh -c "iw dev 2>/dev/null | grep -B1 'type monitor' | grep -A1 'Interface' | grep -E 'Interface.*${INTERFACE}' -A1 | grep 'Interface' | awk '{print \$2}'")
        if [ -n "$DETECTED_MON" ]; then
            echo "$DETECTED_MON"
        else
            echo "Error: Failed to detect monitor interface after activation" >&2
            exit 1
        fi
    fi
else
    # Для деактивации ждём, что целевой интерфейс появился
    if wait_for_interface "$EXPECTED_RESULT" true; then
        echo "$EXPECTED_RESULT"
    else
        echo "Error: Failed to detect managed interface after deactivation" >&2
        exit 1
    fi
fi