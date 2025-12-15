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

# Проверка минимального количества аргументов
if [ $# -lt 2 ]; then
    echo "Usage: $0 <interface> <timeout_seconds> [options]" >&2
    echo "Options:" >&2
    echo "  -c <channels>        Channels to scan (e.g., 1,6,11 or 36-48)" >&2
    echo "  --bssid <mac>        Filter by BSSID" >&2
    echo "  --band <band>        Band to scan (a, b, g, bg, abg)" >&2
    echo "  -w <prefix>          File prefix (optional)" >&2
    echo "" >&2
    echo "Band values (airodump-ng documentation):" >&2
    echo "  a    : 5 GHz" >&2
    echo "  b    : 2.4 GHz (802.11b)" >&2
    echo "  g    : 2.4 GHz (802.11g)" >&2
    echo "  bg   : 2.4 GHz (802.11b+802.11g)" >&2
    echo "  abg  : Both 2.4 GHz and 5 GHz" >&2
    echo "" >&2
    echo "Channel examples:" >&2
    echo "  2.4 GHz: 1,6,11 or 1-11" >&2
    echo "  5 GHz: 36,40,44,48,52,56,60,64,132,136,140,144,149,153,157,161,165" >&2
    exit 1
fi

# Основные параметры
INTERFACE="$1"
TIMEOUT="$2"
shift 2

# Проверка, что timeout - число
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Timeout must be a number" >&2
    exit 1
fi

# Параметры по умолчанию
CHANNELS=""
BSSID=""
BAND=""
FILE_PREFIX=""
DOCKER_IMAGE="wifi:latest"
DATA_DIR="wifi_data"
RECON_DIR="$DATA_DIR/recon"

# Списки валидных каналов для проверки
VALID_24GHZ_CHANNELS=(1 2 3 4 5 6 7 8 9 10 11 12 13)

# UNII-1: (36 40 44 48)
# UNII-2: (52 56 60 64)
# UNII-2-ext: (132 136 140 144)
# UNII-3: (149 153 157 161)
# ISM: (165)
VALID_5GHZ_CHANNELS=(36 40 44 48 52 56 60 64 132 136 140 144 149 153 157 161 165)

# Функция проверки валидности канала
validate_channel() {
    local channel="$1"
    
    # Проверка, что это число
    if ! [[ "$channel" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Канал 0 - специальный (все каналы)
    if [ "$channel" -eq 0 ]; then
        return 0
    fi
    
    # Проверка 2.4 ГГц
    for valid in "${VALID_24GHZ_CHANNELS[@]}"; do
        if [ "$channel" -eq "$valid" ]; then
            return 0
        fi
    done
    
    # Проверка 5 ГГц
    for valid in "${VALID_5GHZ_CHANNELS[@]}"; do
        if [ "$channel" -eq "$valid" ]; then
            return 0
        fi
    done
    
    # Если не нашли в валидных каналах
    return 1
}

# Функция проверки и нормализации каналов
normalize_channels() {
    local channels="$1"
    
    # Если пусто
    if [ -z "$channels" ]; then
        echo ""
        return 0
    fi
    
    # Если указан диапазон через дефис (например, 36-48)
    if [[ "$channels" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        
        # Проверяем оба конца диапазона
        if ! validate_channel "$start"; then
            echo "ERROR: Invalid start channel in range: $start" >&2
            return 1
        fi
        
        if ! validate_channel "$end"; then
            echo "ERROR: Invalid end channel in range: $end" >&2
            return 1
        fi
        
        # Проверяем, что end >= start
        if [ "$end" -lt "$start" ]; then
            echo "ERROR: End channel must be greater than or equal to start channel" >&2
            return 1
        fi
        
        echo "$channels"
        return 0
    fi
    
    # Если указано несколько каналов через запятую
    IFS=',' read -ra channel_array <<< "$channels"
    local valid_channels=()
    
    for ch in "${channel_array[@]}"; do
        ch_clean=$(echo "$ch" | tr -d '[:space:]')
        
        # Проверяем валидность каждого канала
        if ! validate_channel "$ch_clean"; then
            echo "ERROR: Invalid channel: $ch_clean" >&2
            echo "Valid 2.4 GHz channels: ${VALID_24GHZ_CHANNELS[*]}" >&2
            echo "Valid 5 GHz channels: ${VALID_5GHZ_CHANNELS[*]}" >&2
            return 1
        fi
        
        valid_channels+=("$ch_clean")
    done
    
    # Собираем обратно в строку
    echo $(IFS=','; echo "${valid_channels[*]}")
    return 0
}

# Функция для проверки существования интерфейса
check_interface_exists() {
    docker run --rm --net=host --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
        $DOCKER_IMAGE ip link show "$1" >/dev/null 2>&1
    return $?
}

# Парсинг дополнительных аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        -c)
            CHANNELS="$2"
            
            # Нормализуем и проверяем каналы
            NORMALIZED_CHANNELS=$(normalize_channels "$CHANNELS")
            if [ $? -ne 0 ]; then
                exit 1
            fi
            CHANNELS="$NORMALIZED_CHANNELS"
            
            shift 2
            ;;
        --bssid)
            BSSID="$2"
            
            # Базовая проверка формата MAC-адреса
            if ! [[ "$BSSID" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
                echo "WARN: BSSID '$BSSID' may not be a valid MAC address" >&2
                echo "INFO: Continuing anyway, airodump-ng will validate" >&2
            fi
            
            shift 2
            ;;
        --band)
            BAND="$2"
            
            # Проверка валидности диапазона и преобразование значений
            case "$BAND" in
                2.4|bg)
                    BAND="bg"
                    echo "INFO: Scanning 2.4 GHz band (bg)" >&2
                    ;;
                5|a)
                    BAND="a"
                    echo "INFO: Scanning 5 GHz band (a)" >&2
                    ;;
                abg)
                    echo "INFO: Scanning both 2.4 GHz and 5 GHz bands (abg)" >&2
                    ;;
                a|b|g|bg)
                    # Эти значения уже в правильном формате
                    echo "INFO: Using band: $BAND" >&2
                    ;;
                *)
                    echo "ERROR: Invalid band '$BAND'" >&2
                    echo "Valid values: a, b, g, bg, abg, 2.4, 5" >&2
                    exit 1
                    ;;
            esac
            
            shift 2
            ;;
        -w)
            FILE_PREFIX="$2"
            # Удаляем небезопасные символы из префикса
            FILE_PREFIX=$(echo "$FILE_PREFIX" | tr -cd '[:alnum:]_-')
            shift 2
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Проверка конфликтующих опций: нельзя указывать одновременно -c и --band
if [ -n "$CHANNELS" ] && [ -n "$BAND" ]; then
    echo "ERROR: Cannot specify both -c (channels) and --band options simultaneously" >&2
    echo "Use either -c to specify specific channels or --band to use a frequency band" >&2
    exit 1
fi

# Проверка конфликта BSSID и каналов/band
if [ -n "$BSSID" ]; then
    if [ -n "$CHANNELS" ]; then
        echo "INFO: Scanning specific BSSID on channel(s): $CHANNELS" >&2
        echo "      Make sure the BSSID operates on these channels." >&2
    elif [ -n "$BAND" ]; then
        echo "INFO: Scanning specific BSSID on band: $BAND" >&2
        echo "      airodump-ng will automatically switch to the correct channel." >&2
    fi
fi

# Если не указаны ни каналы, ни диапазон - просто сканируем без указания каналов
if [ -z "$CHANNELS" ] && [ -z "$BAND" ]; then
    echo "INFO: No channels or band specified, airodump-ng will scan all channels" >&2
fi

# Создание директории для хранения данных
mkdir -p "$RECON_DIR"

# Генерация имени файла на основе timestamp
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SCAN_DIR="$RECON_DIR/$TIMESTAMP"
if [ -z "$FILE_PREFIX" ]; then
    OUTPUT_PREFIX="$SCAN_DIR/recon"
else
    OUTPUT_PREFIX="$SCAN_DIR/${FILE_PREFIX}"
fi
mkdir -p "$SCAN_DIR"

# Проверка существования интерфейса
if ! check_interface_exists "$INTERFACE"; then
    echo "ERROR: Interface '$INTERFACE' not found or not accessible" >&2
    exit 1
fi

# Формирование команды airodump-ng
AIRODUMP_CMD="airodump-ng --wps --manufacturer --beacons -w $OUTPUT_PREFIX --output-format csv,cap"

# Добавление опциональных параметров
# Приоритет: если указаны каналы, используем их, иначе используем band
if [ -n "$CHANNELS" ]; then
    AIRODUMP_CMD="$AIRODUMP_CMD -c $CHANNELS"
elif [ -n "$BAND" ]; then
    AIRODUMP_CMD="$AIRODUMP_CMD --band $BAND"
fi

if [ -n "$BSSID" ]; then
    AIRODUMP_CMD="$AIRODUMP_CMD --bssid $BSSID"
fi

# Добавление интерфейса команду и дополнительных опций
AIRODUMP_CMD="$AIRODUMP_CMD $INTERFACE"

echo "Starting scan for $TIMEOUT seconds with command:" >&2
echo "  $AIRODUMP_CMD" >&2

# Запуск airodump-ng в Docker-контейнере с таймаутом
if ! docker run --rm \
    --name "airodump-${TIMESTAMP}" \
    --net=host \
    --cap-add=NET_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=SYS_MODULE \
    --cpus="0.5" \
    --memory="1g" \
    -v "$(pwd)/$DATA_DIR/recon:/$DATA_DIR/recon" \
    $DOCKER_IMAGE \
    timeout --signal=INT "${TIMEOUT}s" $AIRODUMP_CMD >/dev/null 2>&1; then
    
    # Проверяем, завершился ли airodump-ng нормально (код 124 или 0 для timeout)
    DOCKER_EXIT_CODE=$?
    if [ $DOCKER_EXIT_CODE -eq 124 ] || [ $DOCKER_EXIT_CODE -eq 0 ]; then
        echo "Scan completed successfully" >&2
    else
        echo "ERROR: airodump-ng failed with exit code $DOCKER_EXIT_CODE" >&2
        exit 1
    fi
fi

# Проверяем, созданы ли выходные файлы
CSV_FILE="${OUTPUT_PREFIX}-01.csv"
CAP_FILE="${OUTPUT_PREFIX}-01.cap"

if [ -f "$CSV_FILE" ]; then
    echo "$CSV_FILE"

    # Выводим информацию о созданных файлах
    echo "Created files:" >&2
    for ext in csv cap; do
        for file in "${OUTPUT_PREFIX}"-*."$ext"; do
            if [ -f "$file" ]; then
                echo "  $(basename "$file")" >&2
            fi
        done
    done

    if [ -f "$CAP_FILE" ]; then
        echo "Launching wash_recon.sh to extract WPS information..." >&2

        # Запускаем wash_recon.sh
        WPS_JSON=$(./wash_recon.sh -f "$CAP_FILE" -w "${FILE_PREFIX:-recon}")

        if [ -f "$WPS_JSON" ]; then
            echo "WPS data saved to: $WPS_JSON" >&2

            # Формируем путь к финальному JSON
            FINAL_JSON="$SCAN_DIR/recon.json"

            echo "Merging data with enrich_recon.py..." >&2
            if python3 enrich_recon.py "$CSV_FILE" "$WPS_JSON" "$FINAL_JSON"; then
                echo "Scan completed successfully!" >&2
                echo "Final enriched JSON: $FINAL_JSON" >&2

                # Удаляем временный WPS-файл после успешного мерджа
                echo "Cleaning up temporary WPS file: $WPS_JSON" >&2
                rm -f "$WPS_JSON"
            else
                echo "ERROR: Failed to run enrich_recon.py" >&2
                exit 1
            fi
        else
            echo "WARNING: wash_recon.sh did not create WPS JSON (maybe no WPS networks found)" >&2
            echo "Continuing without WPS data..." >&2

            # Если WPS-файла нет — создаём recon.json только из CSV
            FINAL_JSON="$SCAN_DIR/recon.json"
            python3 enrich_recon.py "$CSV_FILE" "" "$FINAL_JSON" 2>/dev/null || true
        fi
    else
        echo "WARNING: CAP file not found ($CAP_FILE), skipping WPS analysis" >&2
        FINAL_JSON="$SCAN_DIR/recon.json"
        python3 enrich_recon.py "$CSV_FILE" "" "$FINAL_JSON" 2>/dev/null || true
    fi

else
    echo "ERROR: No output CSV files created" >&2
    exit 1
fi