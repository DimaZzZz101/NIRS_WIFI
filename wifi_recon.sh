#!/bin/bash
#
# wifi-recon.sh - Запуск airodump-ng для сканирования Wi-Fi сетей
#
# Использование: $0 <interface> <timeout> [options]
# Примеры:
#   $0 wlan0mon 30                    # Сканирование 30 секунд на wlan0mon
#   $0 wlan0mon 60 -c 6               # Сканирование на канале 6 (2.4 ГГц)
#   $0 wlan0mon 60 -c 36              # Сканирование на канале 36 (5 ГГц)
#   $0 wlan0mon 60 -c 1,6,11,36,149   # Сканирование на нескольких каналах
#   $0 wlan0mon 60 -c 36-48           # Сканирование диапазона каналов 36-48
#   $0 wlan0mon 120 --bssid AA:BB:CC:DD:EE:FF  # Фильтр по BSSID
#   $0 wlan0mon 120 --band a          # Сканирование 5 ГГц диапазона
#   $0 wlan0mon 120 --band bg         # Сканирование 2.4 ГГц диапазона
#   $0 wlan0mon 120 --band abg        # Сканирование всех диапазонов
#
# Опции:
#   -c <channels>        Каналы для сканирования (через запятую или диапазон)
#   --bssid <mac>        Фильтрация по MAC-адресу точки доступа
#   --band <band>        Диапазон частот (a, b, g, bg, abg)
#   -w <prefix>          Префикс для файлов (опционально)
#
# Выходные файлы сохраняются в wifi_data/recon/<timestamp>/...

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

# Проверка минимального количества аргументов
if [ $# -lt 2 ]; then
    SCRIPT_NAME="$(basename "$0")"
    cat >&2 << EOF
Usage: $SCRIPT_NAME <interface> <timeout_seconds> [options]
Options:
  -c <channels>        Channels to scan (e.g., 1,6,11 or 36-48)
  --bssid <mac>        Filter by BSSID
  --band <band>        Band to scan (a, b, g, bg, abg)
  -w <prefix>          File prefix (optional)

Band values (airodump-ng documentation):
  a    : 5 GHz
  b    : 2.4 GHz (802.11b)
  g    : 2.4 GHz (802.11g)
  bg   : 2.4 GHz (802.11b+802.11g)
  abg  : Both 2.4 GHz and 5 GHz

Channel examples:
  2.4 GHz: 1,6,11 or 1-11
  5 GHz: 36,40,44,48,52,56,60,64,132,136,140,144,149,153,157,161,165

EOF
    exit 1
fi

INTERFACE="$1"
TIMEOUT="$2"
shift 2

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Timeout must be a number" >&2
    exit 1
fi

# Проверка имени интерфейса
if [[ ! "$INTERFACE" =~ ^[a-zA-Z0-9]+([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]; then
    echo "ERROR: Interface name contains invalid characters" >&2
    exit 1
fi

CHANNELS=""
BSSID=""
BAND=""
FILE_PREFIX=""
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
RECON_DIR="$DATA_DIR/recon"

# Валидные каналы
VALID_24GHZ_CHANNELS=(1 2 3 4 5 6 7 8 9 10 11 12 13)
VALID_5GHZ_CHANNELS=(36 40 44 48 52 56 60 64 132 136 140 144 149 153 157 161 165)

validate_channel() {
    local channel="$1"
    if ! [[ "$channel" =~ ^[0-9]+$ ]]; then return 1; fi
    if [ "$channel" -eq 0 ]; then return 0; fi
    for v in "${VALID_24GHZ_CHANNELS[@]}"; do [ "$channel" -eq "$v" ] && return 0; done
    for v in "${VALID_5GHZ_CHANNELS[@]}"; do [ "$channel" -eq "$v" ] && return 0; done
    return 1
}

normalize_channels() {
    local channels="$1"
    if [ -z "$channels" ]; then echo ""; return 0; fi
    if [[ "$channels" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
        if validate_channel "$s" && validate_channel "$e" && [ "$e" -ge "$s" ]; then
            echo "$channels"; return 0
        fi
        echo "ERROR: Invalid channel range" >&2; return 1
    fi
    IFS=',' read -ra arr <<< "$channels"
    local valid=()
    for ch in "${arr[@]}"; do
        ch_clean=$(echo "$ch" | tr -d '[:space:]')
        if validate_channel "$ch_clean"; then valid+=("$ch_clean"); else echo "ERROR: Invalid channel $ch_clean" >&2; return 1; fi
    done
    echo "$(IFS=','; echo "${valid[*]}")"
}

check_interface_exists() {
    docker run --rm --net=host --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        "$DOCKER_IMAGE" ip link show "$1" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c)
            CHANNELS=$(normalize_channels "$2") || exit 1
            shift 2
            ;;
        --bssid)
            BSSID="$2"
            if [[ ! "$BSSID" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                echo "ERROR: Invalid BSSID format" >&2
                exit 1
            fi
            shift 2
            ;;
        --band)
            BAND="$2"
            case "$BAND" in
                2.4) BAND="bg" ;;
                5) BAND="a" ;;
                a|b|g|bg|abg) ;;
                *)
                    echo "ERROR: Invalid band: $BAND" >&2
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        -w)
            FILE_PREFIX=$(echo "$2" | tr -cd '[:alnum:]_-')
            shift 2
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [ -n "$CHANNELS" ] && [ -n "$BAND" ]; then
    echo "ERROR: Cannot use both -c and --band" >&2
    exit 1
fi

mkdir -p "$RECON_DIR"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SCAN_DIR="$RECON_DIR/$TIMESTAMP"
PREFIX="$( [ -z "$FILE_PREFIX" ] && echo "recon" || echo "$FILE_PREFIX" )"
mkdir -p "$SCAN_DIR"

if ! check_interface_exists "$INTERFACE"; then
    echo "ERROR: Interface '$INTERFACE' not found" >&2
    exit 1
fi

AIRODUMP_CMD="airodump-ng --wps --manufacturer --beacons -w /output/$PREFIX --output-format csv,cap"
[ -n "$CHANNELS" ] && AIRODUMP_CMD="$AIRODUMP_CMD -c $CHANNELS"
[ -n "$BAND" ] && AIRODUMP_CMD="$AIRODUMP_CMD --band $BAND"
[ -n "$BSSID" ] && AIRODUMP_CMD="$AIRODUMP_CMD --bssid $BSSID"
AIRODUMP_CMD="$AIRODUMP_CMD $INTERFACE"

echo "Starting Wi-Fi recon for $TIMEOUT seconds..." >&2
echo "Directory: $SCAN_DIR" >&2
echo "airodump-ng command: $AIRODUMP_CMD" >&2

# Запуск airodump-ng
CONTAINER_NAME="airodump-${TIMESTAMP}"
docker run --rm -d \
    --name "$CONTAINER_NAME" \
    --net=host \
    --cap-add=NET_ADMIN --cap-add=NET_RAW --cap-add=SYS_MODULE \
    --cpus="0.5" --memory="1g" \
    -v "$(pwd)/$SCAN_DIR:/output" \
    "$DOCKER_IMAGE" \
    timeout --signal=INT ${TIMEOUT}s $AIRODUMP_CMD

# Ждём завершения или убиваем
(
    sleep "$TIMEOUT"
    docker kill "$CONTAINER_NAME" 2>/dev/null || true
) &

# Ждём завершения контейнера
docker wait "$CONTAINER_NAME" 2>/dev/null || true

# Проверяем файлы
CSV_FILE=$(ls "$SCAN_DIR"/*-01.csv 2>/dev/null | head -1 || true)
CAP_FILE=$(ls "$SCAN_DIR"/*-01.cap 2>/dev/null | head -1 || true)

if [ -z "$CSV_FILE" ]; then
    echo "ERROR: No CSV file created — check interface and monitor mode" >&2
    ls -la "$SCAN_DIR" >&2
    exit 1
fi

echo "$CSV_FILE"

echo "Created files:" >&2
ls "$SCAN_DIR"/*.{csv,cap} 2>/dev/null || true

# 2. wash (если есть .cap)
if [ -n "$CAP_FILE" ]; then
    echo "Running wash on capture..." >&2
    docker run --rm \
        -v "$(pwd)/$SCAN_DIR:/output" \
        "$DOCKER_IMAGE" \
        wash --json -f "/output/$(basename "$CAP_FILE")" > "$SCAN_DIR/wps_temp.json" 2>/dev/null || true
else
    touch "$SCAN_DIR/wps_temp.json"  # пустой, если нет .cap
fi

# 3. enrich_recon (встроенный Python)
echo "Generating recon.json..." >&2
python3 - <<PYTHON "$CSV_FILE" "$SCAN_DIR/wps_temp.json" "$SCAN_DIR/recon.json"
import sys, json, os

csv_path = sys.argv[1]
wps_path = sys.argv[2] if len(sys.argv) > 2 else ""
out_path = sys.argv[3]

with open(csv_path, 'r', encoding='utf-8', errors='ignore') as f:
    lines = [l.rstrip('\n') for l in f if l.strip()]

try:
    ap_end = next(i for i, l in enumerate(lines) if 'Station MAC' in l)
except StopIteration:
    sys.exit(1)

aps = []
for line in lines[2:ap_end]:
    if not line.strip():
        continue
    f = [x.strip() for x in line.split(',')]
    if len(f) < 14:
        continue
    essid = f[13] if len(f) > 13 else ''
    key = f[14] if len(f) > 14 else ''
    aps.append({
        'bssid': f[0],
        'first_seen': f[1],
        'last_seen': f[2],
        'channel': f[3],
        'speed': f[4],
        'privacy': f[5],
        'cipher': f[6],
        'auth': f[7],
        'power': f[8],
        'essid': essid or None,
        'key': key
    })

clients = []
for line in lines[ap_end + 1:]:
    if not line.strip():
        continue
    f = [x.strip() for x in line.split(',')]
    if len(f) < 6:
        continue
    probed = ','.join(f[6:]) if len(f) > 6 else ''
    clients.append({
        'station_mac': f[0],
        'power': f[3],
        'packets': f[4],
        'probed_essids': probed,
        'associated_bssid': f[5]
    })

wash_data = {}
if wps_path and os.path.exists(wps_path):
    with open(wps_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
                b = item.get('bssid', '').upper()
                if b:
                    clean_wps = {
                        'enabled': True,
                        'version': "2.0" if item.get('wps_version') == 32 else "1.0" if item.get('wps_version') == 16 else None,
                        'locked': item.get('wps_locked') == 2,
                        'locked_status': "Yes" if item.get('wps_locked') == 2 else "No",
                        'manufacturer': item.get('wps_manufacturer'),
                        'model_name': item.get('wps_model_name'),
                        'model_number': item.get('wps_model_number'),
                        'device_name': item.get('wps_device_name'),
                        'config_methods': item.get('wps_config_methods'),
                        'rf_bands': item.get('wps_rf_bands')
                    }
                    clean_wps = {k: v for k, v in clean_wps.items() if v is not None}
                    wash_data[b] = clean_wps
            except:
                pass

client_map = {}
for c in clients:
    b = c['associated_bssid'].upper()
    if '(NOT ASSOCIATED)' in c['associated_bssid'].lower():
        continue
    clean_c = {
        'mac': c['station_mac'],
        'power': c['power'],
        'packets': c['packets'],
        'probed_essids': c['probed_essids'] or None,
        'associated_ap': c['associated_bssid']
    }
    client_map.setdefault(b, []).append(clean_c)

result = []
for ap in aps:
    bu = ap['bssid'].upper()
    result.append({
        'bssid': ap['bssid'],
        'essid': ap['essid'],
        'channel': ap['channel'],
        'power': ap['power'],
        'privacy': ap['privacy'],
        'auth': ap['auth'],
        'clients': client_map.get(bu, []),
        'wps': wash_data.get(bu, {'enabled': False, 'version': None, 'locked': False, 'locked_status': "N/A"})
    })

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(result, f, indent=4, ensure_ascii=False)

print(f"Final enriched JSON saved: {out_path}")
PYTHON

# Удаляем временный wps-файл
rm -f "$SCAN_DIR/wps_temp.json"

echo "Scan completed successfully!" >&2