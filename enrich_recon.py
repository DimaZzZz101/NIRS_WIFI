import sys
import json

def parse_airodump_csv(csv_path):
    with open(csv_path, 'r', encoding='utf-8', errors='ignore') as f:
        lines = [line.rstrip('\n') for line in f if line.strip()]

    try:
        ap_end = next(i for i, line in enumerate(lines) if 'Station MAC' in line)
    except StopIteration:
        print("ERROR: Could not find 'Station MAC' section in CSV", file=sys.stderr)
        sys.exit(1)

    # Парсим Access Points
    ap_lines = lines[2:ap_end]
    aps = []
    for line in ap_lines:
        if not line.strip():
            continue
        fields = [f.strip() for f in line.split(',')]
        if len(fields) < 14:
            continue
        key = fields[14] if len(fields) > 14 else ''
        aps.append({
            'bssid': fields[0],
            'first_seen': fields[1],
            'last_seen': fields[2],
            'channel': fields[3],
            'speed': fields[4],
            'privacy': fields[5],
            'cipher': fields[6],
            'auth': fields[7],
            'power': fields[8],
            'essid': fields[13],
            'key': key
        })

    # Парсим клиентов — сохраняем BSSID для последующей привязки
    client_lines = lines[ap_end + 1:]
    clients = []
    for line in client_lines:
        if not line.strip():
            continue
        fields = [f.strip() for f in line.split(',')]
        if len(fields) < 6:
            continue
        associated_bssid = fields[5]
        probed = ','.join(fields[6:]) if len(fields) > 6 else ''
        clients.append({
            'station_mac': fields[0],
            'power': fields[3],
            'packets': fields[4],
            'probed_essids': probed,
            'associated_bssid': associated_bssid  # Сохраняем оригинальный BSSID
        })

    return aps, clients

def load_wash_json(json_path):
    wash_data = {}
    with open(json_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
                bssid = item.get('bssid', '').upper()
                if not bssid:
                    continue
                
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
                wash_data[bssid] = clean_wps
            except json.JSONDecodeError:
                continue
    return wash_data

def merge_data(aps, clients, wash_data):
    # Группируем клиентов по BSSID AP
    client_map = {}
    for client in clients:
        bssid = client['associated_bssid'].upper()
        if '(NOT ASSOCIATED)' in client['associated_bssid'].lower():
            continue  # Пропускаем неассоциированных
        clean_client = {
            'mac': client['station_mac'],
            'power': client['power'],
            'packets': client['packets'],
            'probed_essids': client['probed_essids'] or None,
            'associated_ap': client['associated_bssid']  # ← Добавляем MAC ТД!
        }
        client_map.setdefault(bssid, []).append(clean_client)

    # Собираем результат
    result = []
    for ap in aps:
        bssid_upper = ap['bssid'].upper()
        clean_ap = {
            'bssid': ap['bssid'],
            'essid': ap['essid'] or None,
            'channel': ap['channel'],
            'power': ap['power'],
            'privacy': ap['privacy'] or None,
            'auth': ap['auth'],
            'clients': client_map.get(bssid_upper, []),
            'wps': wash_data.get(bssid_upper, {
                'enabled': False,
                'version': None,
                'locked': False,
                'locked_status': "N/A"
            })
        }
        result.append(clean_ap)

    return result

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python3 enrich_recon.py <airodump_csv> <wash_json> <output_json>")
        sys.exit(1)

    csv_path = sys.argv[1]
    json_path = sys.argv[2]
    output_path = sys.argv[3]

    aps, clients = parse_airodump_csv(csv_path)
    wash_data = load_wash_json(json_path)
    merged = merge_data(aps, clients, wash_data)

    with open(output_path, 'w', encoding='utf-8') as f:
        json.dump(merged, f, indent=4, ensure_ascii=False)

    print(f"Clean merged data ({len(merged)} APs) saved to {output_path}")