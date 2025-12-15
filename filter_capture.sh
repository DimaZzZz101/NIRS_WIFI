#!/bin/bash
#
# filter_capture.sh - Фильтрация .cap-файла по BSSID (handshake + management) с помощью tshark
#
# Использование: $0 <input_cap> <bssid> [options]
# Пример:
#   $0 wifi_data/recon/20251213_211302/recon-01.cap AA:BB:CC:DD:EE:FF
#   $0 recon-01.cap AA:BB:CC:DD:EE:FF -w target
#
# Опции:
#   -w <prefix>          Префикс для выходного файла (по умолчанию: handshake)
#
# Выходной файл: wifi_data/handshakes/<timestamp>_<prefix>.pcapng

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <input_cap_file> <bssid> [options]" >&2
    echo "Options:" >&2
    echo "  -w <prefix>          Output file prefix (default: handshake)" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 wifi_data/recon/20251213_211302/recon-01.cap AA:BB:CC:DD:EE:FF" >&2
    exit 1
fi

INPUT_CAP="$1"
BSSID="$2"
shift 2

FILE_PREFIX="handshake"
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
HANDSHAKE_DIR="$DATA_DIR/handshakes"

while [[ $# -gt 0 ]]; do
    case $1 in
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

if [ ! -f "$INPUT_CAP" ]; then
    echo "ERROR: Input .cap file not found: $INPUT_CAP" >&2
    exit 1
fi

if ! [[ "$BSSID" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "ERROR: Invalid BSSID format: $BSSID" >&2
    exit 1
fi

# Создаём директорию для handshake'ов
mkdir -p "$HANDSHAKE_DIR"

# Генерируем timestamp и имя выходного файла
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTPUT_FILE="$HANDSHAKE_DIR/${TIMESTAMP}_${FILE_PREFIX}.pcapng"

BSSID_LOWER=$(echo "$BSSID" | tr '[:upper:]' '[:lower:]')

# Фильтр: management фреймы + EAPOL, где BSSID встречается в любом адресном поле
TSHARK_FILTER="(wlan.fc.type_subtype == 0x00 || wlan.fc.type_subtype == 0x02 || wlan.fc.type_subtype == 0x04 || wlan.fc.type_subtype == 0x05 || wlan.fc.type_subtype == 0x08 || eapol) && wlan.addr == $BSSID_LOWER"

echo "Filtering capture for BSSID: $BSSID" >&2
echo "Input:  $INPUT_CAP" >&2
echo "Output: $OUTPUT_FILE" >&2

docker run --rm \
    --name "tshark-filter-$(date '+%H%M%S')" \
    --cpus="0.5" \
    --memory="1g" \
    -v "$(pwd)/$DATA_DIR:/$DATA_DIR" \
    $DOCKER_IMAGE \
    tshark -r "/$INPUT_CAP" -Y "$TSHARK_FILTER" -w "/$OUTPUT_FILE" -F pcap

if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
    echo "Filtered capture (handshake candidate) saved successfully:" >&2
    echo "  $OUTPUT_FILE (size: $SIZE)" >&2
    echo "" >&2
else
    echo "WARNING: No packets matched the filter (possible no handshake or wrong BSSID)" >&2
    rm -f "$OUTPUT_FILE"
fi