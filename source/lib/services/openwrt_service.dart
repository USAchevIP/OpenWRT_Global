import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import '../models/router_connection.dart';
import '../models/system_info.dart';
import '../models/wifi_info.dart';
import '../models/client_info.dart';
import '../models/package_info.dart';
import '../models/network_info.dart';
import '../models/vpn_info.dart';
import '../models/channel_scan_result.dart';

class OpenWrtService {
  final RouterConnection config;
  SSHClient? _client;
  bool _connected = false;
  Timer? _keepAliveTimer;

  OpenWrtService(this.config);

  bool get isConnected => _connected;

  SSHClient? get sshClient => _client;

  Future<void> connect() async {
    try {
      final socket = await SSHSocket.connect(config.host, config.port);
      if (config.useKey && config.sshKey != null && config.sshKey!.isNotEmpty) {
        final keyPairs = SSHKeyPair.fromPem(config.sshKey!);
        _client = SSHClient(
          socket,
          username: config.username,
          identities: keyPairs,
          onPasswordRequest: () => null,
        );
      } else {
        _client = SSHClient(
          socket,
          username: config.username,
          onPasswordRequest: () => config.password,
        );
      }
      await _client!.run('echo ok');
      _startKeepAlive();
      _connected = true;
    } catch (e) {
      _connected = false;
      throw Exception('Ошибка подключения SSH: ${e.toString().replaceAll(config.password, '***')}');
    }
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_client == null) return;
      try {
        await _client!.run('echo keepalive');
      } catch (_) {
        _connected = false;
      }
    });
  }

  Future<void> reconnect() async {
    await disconnect();
    await connect();
  }

  Future<void> disconnect() async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _client?.close();
    _client = null;
    _connected = false;
  }

  Future<String> runCommand(String command) async {
    if (_client == null) {
      await reconnect();
    }
    try {
      final result = await _client!.run(command).timeout(const Duration(seconds: 30));
      _connected = true;
      return utf8.decode(result);
    } catch (e) {
      _connected = false;
      // Пробуем один раз переподключиться
      try {
        await reconnect();
        final result = await _client!.run(command).timeout(const Duration(seconds: 30));
        _connected = true;
        return utf8.decode(result);
      } catch (e2) {
        throw Exception('SSH ошибка: ${e2.toString().replaceAll(config.password, '***')}');
      }
    }
  }

  Future<SystemInfo> fetchSystemInfo() async {
    try {
      final raw = await runCommand('ubus call system info 2>/dev/null || echo "{}"');
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json.isNotEmpty && json['hostname'] != null) {
        return SystemInfo.fromUbusJson(json);
      }
    } catch (_) {}

    // Fallback: читаем /proc напрямую
    try {
      final memRaw = await runCommand(r"awk '/MemTotal|MemAvailable|MemFree/{print $2}' /proc/meminfo 2>/dev/null || echo '0\n0\n0'");
      final memLines = LineSplitter.split(memRaw).toList();
      final memTotal = int.tryParse(memLines.isNotEmpty ? memLines[0] : '0') ?? 0;
      final memAvail = int.tryParse(memLines.length > 1 ? memLines[1] : (memLines.length > 2 ? memLines[2] : '0')) ?? 0;

      final loadRaw = await runCommand("cat /proc/loadavg 2>/dev/null || echo '0 0 0'");
      final loadParts = loadRaw.trim().split(RegExp(r'\s+'));
      final load1 = double.tryParse(loadParts.isNotEmpty ? loadParts[0] : '0') ?? 0;

      final uptimeRaw = await runCommand(r"awk '{print $1}' /proc/uptime 2>/dev/null || echo '0'");
      final uptime = int.tryParse(uptimeRaw.split('.').first) ?? 0;

      String? model, firmware, kernel, hostname;
      try {
        final boardRaw = await runCommand('ubus call system board 2>/dev/null || echo "{}"');
        final board = jsonDecode(boardRaw) as Map<String, dynamic>;
        model = board['model']?.toString() ?? board['board_name']?.toString();
        hostname = board['hostname']?.toString();
        kernel = board['kernel']?.toString();
        final release = board['release'] is Map ? board['release'] as Map<String, dynamic> : {};
        firmware = '${release['distribution'] ?? 'OpenWrt'} ${release['version'] ?? ''}'.trim();
      } catch (_) {}

      return SystemInfo(
        hostname: hostname ?? 'OpenWrt',
        model: model ?? 'Unknown',
        firmwareVersion: firmware ?? 'OpenWrt',
        kernelVersion: kernel ?? '',
        uptime: '${(uptime / 3600).toStringAsFixed(1)} ч.',
        cpuLoad: load1,
        memoryTotal: memTotal * 1024,
        memoryFree: memAvail * 1024,
        memoryUsed: (memTotal - memAvail) * 1024,
      );
    } catch (_) {}

    return SystemInfo(
      hostname: 'OpenWrt', model: 'Unknown', firmwareVersion: 'OpenWrt',
      kernelVersion: '', uptime: '0 мин.', cpuLoad: 0, memoryTotal: 0, memoryFree: 0, memoryUsed: 0,
    );
  }

  Future<Map<String, dynamic>> fetchBoardInfo() async {
    final raw = await runCommand('ubus call system board');
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<List<WifiDevice>> fetchWirelessDevices() async {
    final raw = await runCommand('ubus call network.wireless status 2>/dev/null || echo "{}"');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final List<WifiDevice> devices = [];
    for (final entry in data.entries) {
      final name = entry.key;
      final value = entry.value;
      if (value is Map<String, dynamic>) {
        String? htMode = value['config']?['htmode']?.toString();
        if (htMode == null || htMode.isEmpty) {
          try {
            htMode = (await runCommand('uci get wireless.$name.htmode 2>/dev/null || echo ""')).trim();
            if (htMode.isEmpty) htMode = null;
          } catch (_) {}
        }
        devices.add(WifiDevice(
          name: name,
          up: value['up'] == true,
          mac: value['config']?['macaddr']?.toString(),
          channel: value['config']?['channel']?.toString(),
          band: value['config']?['band']?.toString(),
          txPower: int.tryParse(value['config']?['txpower']?.toString() ?? ''),
          hwMode: value['config']?['hwmode']?.toString(),
          htMode: htMode,
        ));
      }
    }
    return devices;
  }

  Future<List<WifiNetwork>> fetchWifiNetworks() async {
    final raw = await runCommand('uci show wireless 2>/dev/null || echo ""');
    final networks = <WifiNetwork>[];
    final sections = <String, Map<String, String>>{};

    for (final line in LineSplitter.split(raw)) {
      final idx = line.indexOf('=');
      if (idx == -1) continue;
      final key = line.substring(0, idx).trim();
      final value = line.substring(idx + 1).trim().replaceAll("'", "").replaceAll('"', '');
      final match = RegExp(r'^wireless\.([^.]+)\.(ssid|device|disabled|encryption|mode|network)$').firstMatch(key);
      if (match != null) {
        final section = match.group(1)!;
        final field = match.group(2)!;
        sections.putIfAbsent(section, () => {});
        sections[section]![field] = value;
      }
    }

    final rawSections = await runCommand('uci show wireless 2>/dev/null | grep -E "^wireless\\.[^=]+=wifi-iface" || echo ""');
    final ifaceSections = <String>{};
    for (final line in LineSplitter.split(rawSections)) {
      final match = RegExp(r'^wireless\.([^=]+)=wifi-iface').firstMatch(line);
      if (match != null) ifaceSections.add(match.group(1)!);
    }

    for (final section in ifaceSections) {
      final fields = sections[section] ?? {};
      if (fields.isEmpty) continue;
      networks.add(WifiNetwork(
        section: section,
        ssid: fields['ssid'] ?? '',
        device: fields['device'] ?? '',
        disabled: fields['disabled'] == '1',
        encryption: fields['encryption'],
        mode: fields['mode'],
      ));
    }
    return networks;
  }

  Future<void> toggleWifiNetwork(String section, bool enable) async {
    await runCommand('uci set wireless.$section.disabled=${enable ? '0' : '1'}; uci commit wireless; wifi reload');
  }

  Future<void> setWifiChannel(String device, String channel) async {
    await runCommand('uci set wireless.$device.channel=$channel; uci commit wireless; wifi reload');
  }

  Future<Map<int, int>> scanWifiChannels(String device) async {
    final raw = await runCommand('iwinfo $device scan 2>/dev/null || iw dev $device scan 2>/dev/null || echo ""');
    final channels = <int, int>{};
    final re = RegExp(r'Channel:\s*(\d+)|channel:\s*(\d+)', caseSensitive: false);
    for (final m in re.allMatches(raw)) {
      final ch = int.tryParse(m.group(1) ?? m.group(2) ?? '');
      if (ch != null) {
        channels[ch] = (channels[ch] ?? 0) + 1;
      }
    }
    return channels;
  }

  Future<List<ChannelScanResult>> scanWifiChannelsDetailed(String device) async {
    final raw = await runCommand('iwinfo $device scan 2>/dev/null || iw dev $device scan 2>/dev/null || echo ""');
    final results = <ChannelScanResult>[];
    String? currentSsid, currentBssid, currentSig, currentCh;
    int currentWidth = 20;
    int currentCenterFreq = 0;

    for (final line in LineSplitter.split(raw)) {
      final trimmed = line.trim();

      // Новая BSS (точка доступа)
      if (trimmed.startsWith('BSS ') || trimmed.startsWith('ESSID:') || trimmed.startsWith('SSID:')) {
        _finalizeScanResult(results, currentSsid, currentBssid, currentSig, currentCh, currentWidth, currentCenterFreq);
        if (trimmed.startsWith('BSS ')) {
          currentBssid = trimmed.split(' ')[1].toLowerCase();
          currentSsid = null; currentSig = null; currentCh = null;
          currentWidth = 20; currentCenterFreq = 0;
        } else {
          currentSsid = trimmed.substring(trimmed.indexOf(':') + 1).trim().replaceAll('"', '').replaceAll("'", '');
          currentBssid = null; currentSig = null; currentCh = null;
          currentWidth = 20; currentCenterFreq = 0;
        }
        continue;
      }

      if (trimmed.startsWith('BSSID:')) {
        final m = RegExp(r'([0-9a-fA-F:]{17})').firstMatch(trimmed);
        if (m != null) currentBssid = m.group(1)!.toLowerCase();
      }

      // Сигнал
      if (currentSig == null) {
        final sigMatch = RegExp(r'Signal:\s*(-?\d+)\s*dBm|signal:\s*(-?\d+)', caseSensitive: false).firstMatch(trimmed);
        if (sigMatch != null) currentSig = sigMatch.group(1) ?? sigMatch.group(2);
      }

      // Канал
      if (currentCh == null) {
        final chMatch = RegExp(r'Channel:\s*(\d+)|channel:\s*(\d+)', caseSensitive: false).firstMatch(trimmed);
        if (chMatch != null) currentCh = chMatch.group(1) ?? chMatch.group(2);
      }

      // Ширина канала: HT operation → STA channel width
      if (trimmed.contains('STA channel width:') || trimmed.contains('channel width:')) {
        final m = RegExp(r'(\d+)\s*MHz').firstMatch(trimmed);
        if (m != null) {
          final w = int.tryParse(m.group(1)!) ?? 20;
          if (w >= 20 && w <= 320) currentWidth = w;
        }
      }
      // HE operation parameters
      if (trimmed.contains('HE operation parameters:')) {
        final m = RegExp(r'(\d+)\s*MHz').firstMatch(trimmed);
        if (m != null) {
          final w = int.tryParse(m.group(1)!) ?? 20;
          if (w >= 20 && w <= 320) currentWidth = w;
        }
      }
      // secondary channel offset for HT40 detection
      if (trimmed.contains('secondary channel offset:') && trimmed.contains('above') || trimmed.contains('below')) {
        if (currentWidth == 20) currentWidth = 40;
      }

      // Центральная частота
      if (trimmed.contains('center freq segment') || trimmed.contains('Center freq')) {
        final cf = RegExp(r'(\d+)').firstMatch(trimmed);
        if (cf != null) {
          final freq = int.tryParse(cf.group(1)!) ?? 0;
          if (freq > 1000 && freq != currentCenterFreq) currentCenterFreq = freq;
        }
      }
    }
    _finalizeScanResult(results, currentSsid, currentBssid, currentSig, currentCh, currentWidth, currentCenterFreq);
    return results;
  }

  void _finalizeScanResult(List<ChannelScanResult> results, String? ssid, String? bssid, String? sig, String? ch, int width, int centerFreq) {
    if (ch == null) return;
    final channel = int.tryParse(ch);
    if (channel == null || channel == 0) return;
    final centerCh = centerFreq > 0 ? (centerFreq - 2407) ~/ 5 : channel;
    results.add(ChannelScanResult(
      channel: channel,
      frequency: centerFreq > 0 ? centerFreq : (channel * 5 + 2407),
      width: width,
      centerChannel: centerCh,
      signalStrength: int.tryParse(sig ?? '-100') ?? -100,
      ssid: ssid ?? '',
      bssid: bssid ?? '',
      source: 'router',
    ));
  }

  /// Wi-Fi аудит безопасности: WPS, перехват PMKID, чтение пароля из UCI
  Future<Map<String, dynamic>> wifiSecurityAudit(String iface, String bssid) async {
    final result = <String, dynamic>{
      'wps': false, 'locked': false, 'password': null,
      'method': null, 'pmkid': null, 'encryption': null,
    };
    // 1. WPS статус
    final raw = await runCommand('iw dev $iface scan 2>/dev/null | grep -A 30 "BSS $bssid" || echo ""');
    result['wps'] = raw.contains('WPS:');
    result['locked'] = raw.contains('0x15');
    // 2. Шифрование
    if (raw.contains('WPA3') || raw.contains('SAE')) result['encryption'] = 'WPA3';
    else if (raw.contains('WPA2') || raw.contains('CCMP')) result['encryption'] = 'WPA2';
    else if (raw.contains('WPA')) result['encryption'] = 'WPA';
    else if (raw.contains('WEP')) result['encryption'] = 'WEP';
    else result['encryption'] = 'Открытая';
    // 3. Пароль из UCI (если наша сеть)
    try {
      final networks = await fetchWifiNetworks();
      for (final n in networks) {
        if (n.ssid == (result['ssid'] ?? '')) {
          final key = await runCommand('uci get wireless.${n.section}.key 2>/dev/null || echo ""');
          if (key.trim().isNotEmpty) {
            result['password'] = key.trim();
            result['method'] = 'uci_config';
          }
          break;
        }
      }
    } catch (_) {}
    // 4. Попытка перехвата PMKID через hcxdumptool (если установлен)
    try {
      final hasHcx = await runCommand('which hcxdumptool 2>/dev/null && echo OK || echo NO').then((s) => s.trim());
      if (hasHcx == 'OK') {
        await runCommand('timeout 10 hcxdumptool -i $iface -o /tmp/pmkid.pcapng --enable_status=1 2>/dev/null || true');
        final hasFile = await runCommand('test -s /tmp/pmkid.pcapng && echo OK || echo NO').then((s) => s.trim());
        if (hasFile == 'OK') {
          await runCommand('hcxpcapngtool -o /tmp/hash.txt /tmp/pmkid.pcapng 2>/dev/null || true');
          final pass = await runCommand('hashcat -m 22000 /tmp/hash.txt --show 2>/dev/null | head -1 || echo ""');
          if (pass.trim().isNotEmpty && !pass.contains('hashcat') && !pass.contains('Separator')) {
            result['password'] = pass.trim().split(':').last;
            result['method'] = 'pmkid_crack';
            result['pmkid'] = '/tmp/hash.txt';
          }
        }
      }
    } catch (_) {}
    return result;
  }

  Future<int?> recommendChannel(String device) async {
    final channels = await scanWifiChannels(device);
    if (channels.isEmpty) return null;
    final band = await runCommand('uci get wireless.$device.band 2>/dev/null || echo ""');
    final is5G = band.trim() == '5g';
    final candidates = is5G
        ? List.generate(25, (i) => 36 + i * 4).where((c) => c <= 165)
        : List.generate(13, (i) => i + 1);
    int? best;
    int bestCount = 999999;
    for (final ch in candidates) {
      final count = channels[ch] ?? 0;
      if (count < bestCount) {
        bestCount = count;
        best = ch;
      }
    }
    return best;
  }

  Future<List<int>> getAvailableChannels(String device) async {
    final raw = await runCommand('iwinfo $device freqlist 2>/dev/null || iw dev $device info 2>/dev/null || echo ""');
    final channels = <int>{};
    // iwinfo freqlist: "* 2412 MHz [Channel 1]" или "2412 MHz [1]"
    final re = RegExp(r'Channel\s*(\d+)|\[(\d+)\]', caseSensitive: false);
    for (final m in re.allMatches(raw)) {
      final ch = int.tryParse(m.group(1) ?? m.group(2) ?? '');
      if (ch != null) channels.add(ch);
    }
    if (channels.isEmpty) {
      // fallback: все доступные каналы по band
      final band = await runCommand('uci get wireless.$device.band 2>/dev/null || echo ""');
      if (band.trim() == '5g') {
        return List.generate(25, (i) => 36 + i * 4).where((c) => c <= 165).toList();
      }
      return List.generate(13, (i) => i + 1).toList(); // Все 13 каналов 2.4 ГГц
    }
    return channels.toList()..sort();
  }

  Future<void> setWifiNetwork({
    required String section,
    required String ssid,
    String? encryption,
    String? key,
  }) async {
    String esc(String s) => s.replaceAll("'", "'\\''").replaceAll('"', '\\"');
    final cmd = StringBuffer();
    cmd.write("uci set wireless.$section.ssid='${esc(ssid)}'; ");
    if (encryption != null) {
      cmd.write("uci set wireless.$section.encryption='${esc(encryption)}'; ");
      if (encryption == 'none') {
        cmd.write("uci delete wireless.$section.key; ");
      } else if (key != null && key.isNotEmpty) {
        cmd.write("uci set wireless.$section.key='${esc(key)}'; ");
      }
    }
    cmd.write('uci commit wireless; wifi reload');
    await runCommand(cmd.toString());
  }

  Future<List<String>> getAvailableHtModes(String device) async {
    // Available hwmodes: HT20, HT40, VHT20, VHT40, VHT80, VHT160, HE*, NOHT
    final band = await runCommand('uci get wireless.$device.band 2>/dev/null || echo ""').then((s) => s.trim());
    if (band == '5g' || band == '6g') {
      return ['HE20', 'HE40', 'HE80', 'HE160', 'VHT20', 'VHT40', 'VHT80', 'VHT160', 'HT20', 'HT40', 'NOHT'];
    }
    return ['HT20', 'HT40', 'HE20', 'HE40', 'NOHT'];
  }

  Future<void> setWifiHtMode(String device, String htMode) async {
    // Сначала чистим возможный мусор от старого бага
    await runCommand("uci get wireless.$device.htmode 2>/dev/null | grep -q '\\\${' && uci delete wireless.$device.htmode || true");
    await runCommand("uci set wireless.$device.htmode='$htMode'; uci commit wireless; wifi reload");
  }

  Future<String> runSpeedtest() async {
    // Метод 1: iperf3 (если установлен)
    try {
      final hasIperf = await runCommand('which iperf3 2>/dev/null && echo OK || echo NO').then((s) => s.trim());
      if (hasIperf == 'OK') {
        // Ищем публичный iperf3 сервер
        final servers = [
          'iperf.volia.net:5201',
          'iperf.he.net:5201',
          'iperf.online.net:5201',
        ];
        for (final server in servers) {
          try {
            final r = await runCommand('iperf3 -c ${server.split(':')[0]} -p ${server.split(':')[1]} -t 10 -f m 2>&1 | tail -5').timeout(const Duration(seconds: 20));
            if (r.contains('receiver') || r.contains('sender')) {
              final dlMatch = RegExp(r'(\d+\.?\d*)\s*Mbits/sec').firstMatch(r);
              if (dlMatch != null) {
                return 'iperf3: ${dlMatch.group(1)} Мбит/с\nСервер: $server';
              }
            }
          } catch (_) {
            continue;
          }
        }
      }
    } catch (_) {}

    // Метод 2: speedtest-netperf (если установлен)
    try {
      final hasNetperf = await runCommand('which speedtest-netperf 2>/dev/null && echo OK || echo NO').then((s) => s.trim());
      if (hasNetperf == 'OK') {
        final r = await runCommand('speedtest-netperf 2>/dev/null').timeout(const Duration(seconds: 45));
        if (r.isNotEmpty && (r.contains('Download') || r.contains('download'))) {
          final dl = RegExp(r'Download:\s*(\d+\.?\d*)\s*(Mbps|Mbit)', caseSensitive: false).firstMatch(r);
          final ul = RegExp(r'Upload:\s*(\d+\.?\d*)\s*(Mbps|Mbit)', caseSensitive: false).firstMatch(r);
          return 'speedtest-netperf:\n'
              '${dl != null ? "Входящая: ${dl.group(1)} Мбит/с" : ""}\n'
              '${ul != null ? "Исходящая: ${ul.group(1)} Мбит/с" : ""}';
        }
      }
    } catch (_) {}

    // Метод 3: curl с замером (самый надёжный)
    try {
      final hasCurl = await runCommand('which curl 2>/dev/null && echo OK || echo NO').then((s) => s.trim());
      if (hasCurl == 'OK') {
        final r = await runCommand(
          'curl -o /dev/null -w "DL|%{speed_download}|UL|%{speed_upload}|SIZE|%{size_download}|TIME|%{time_total}" -s '
          'http://speedtest.tele2.net/10MB.zip 2>/dev/null; echo OK'
        ).timeout(const Duration(seconds: 60));
        if (r.contains('OK')) {
          final dl = _extract(r, 'DL|', '|UL');
          final ul = _extract(r, 'UL|', '|SIZE');
          final sz = _extract(r, 'SIZE|', '|TIME');
          final tm = _extract(r, 'TIME|', null);
          final dlMbps = ((double.tryParse(dl) ?? 0) * 8 / 1000000).toStringAsFixed(1);
          final ulMbps = ((double.tryParse(ul) ?? 0) * 8 / 1000000).toStringAsFixed(1);
          final szMB = ((double.tryParse(sz) ?? 0) / 1048576).toStringAsFixed(1);
          return 'curl speedtest:\n'
              'Входящая: $dlMbps Мбит/с\n'
              'Исходящая: $ulMbps Мбит/с\n'
              'Скачано: $szMB МБ за $tm сек';
        }
      }
    } catch (_) {}

    // Метод 4 (fallback): wget
    try {
      final r = await runCommand(
        'wget -O /dev/null http://speedtest.tele2.net/1MB.zip 2>&1; echo OK'
      ).timeout(const Duration(seconds: 30));
      if (r.contains('OK')) {
        for (final line in LineSplitter.split(r)) {
          final m = RegExp(r'(\d+\.?\d*)\s*([KM])B/s', caseSensitive: false).firstMatch(line);
          if (m != null) {
            final speed = double.tryParse(m.group(1)!) ?? 0;
            final mbps = (m.group(2)!.toUpperCase() == 'K' ? speed * 8 / 1000 : speed * 8).toStringAsFixed(1);
            return 'wget speedtest:\nВходящая: $mbps Мбит/с';
          }
        }
        return 'wget speedtest: тест завершён, но скорость не распознана.\nУстановите: opkg install curl iperf3';
      }
    } catch (_) {}

    // Ничего не сработало
    return 'Speedtest не выполнен.\n'
        'Установите: opkg update && opkg install curl iperf3 speedtest-netperf\n'
        'Или проверьте интернет на роутере';
  }

  String _extract(String s, String start, String? end) {
    final a = s.indexOf(start); if (a < 0) return '?';
    final v = s.substring(a + start.length);
    if (end == null) return v.trim();
    final b = v.indexOf(end);
    return b < 0 ? v.trim() : v.substring(0, b).trim();
  }

  String _fmt(String r) => r;

  Future<void> addGuestNetwork({required String radioDevice, required String ssid}) async {
    final cmd = """
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='\${radioDevice}'
uci set wireless.@wifi-iface[-1].network='guest'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].ssid='\${ssid}'
uci set wireless.@wifi-iface[-1].encryption='none'
uci set wireless.@wifi-iface[-1].isolate='1'
uci add_list network.lan.ipaddr='10.0.0.1/24' 2>/dev/null || true
uci set network.guest=interface
uci set network.guest.proto='static'
uci set network.guest.ipaddr='192.168.3.1'
uci set network.guest.netmask='255.255.255.0'
uci add firewall zone 2>/dev/null || true
uci set firewall.@zone[-1].name='guest'
uci set firewall.@zone[-1].network='guest'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci commit wireless
uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload
wifi reload
""";
    await runCommand(cmd);
  }

  Future<void> toggleGuestNetwork(String section, bool enable) async {
    await runCommand("uci set wireless.\$section.disabled=\${enable ? '0' : '1'}; uci commit wireless; wifi reload");
  }

  Future<void> scheduleWifi(String section, {String? start, String? stop, bool? enabled}) async {
    if (enabled != null) {
      await runCommand("uci set wireless.\$section.sched_enabled=\${enabled ? '1' : '0'}");
    }
    if (start != null) {
      await runCommand("uci set wireless.\$section.sched_start='\${start}'");
    }
    if (stop != null) {
      await runCommand("uci set wireless.\$section.sched_stop='\${stop}'");
    }
    await runCommand('uci commit wireless');
  }

  Future<void> addPortForward({
    required String name,
    required String srcDport,
    required String destIp,
    required String destPort,
    String proto = 'tcp',
  }) async {
    final cmd = """
uci add firewall redirect
uci set firewall.@redirect[-1].name='\${name}'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].proto='\${proto}'
uci set firewall.@redirect[-1].src_dport='\${srcDport}'
uci set firewall.@redirect[-1].dest_ip='\${destIp}'
uci set firewall.@redirect[-1].dest_port='\${destPort}'
uci set firewall.@redirect[-1].target='DNAT'
uci commit firewall
/etc/init.d/firewall reload
""";
    await runCommand(cmd);
  }

  Future<void> deletePortForward(String section) async {
    await runCommand("uci delete firewall.$section; uci commit firewall; /etc/init.d/firewall reload");
  }

  Future<String> backupConfig() async {
    return runCommand('sysupgrade -b - 2>/dev/null | base64 || (tar czf - /etc/config 2>/dev/null | base64)');
  }

  Future<void> restoreConfig(String base64Config) async {
    await runCommand("echo '\$base64Config' | base64 -d | sysupgrade -r - || true");
    await runCommand('reboot');
  }

  Future<void> wakeOnLan(String mac) async {
    await runCommand("which wol 2>/dev/null && wol '\$mac' || (opkg install wol 2>/dev/null && wol '\$mac') || echo 'wol not available'");
  }

  Future<String> fetchDnsSettings() async {
    return runCommand('uci show dhcp 2>/dev/null | grep "dns" || echo ""');
  }

  Future<void> setDns(List<String> servers) async {
    for (final s in servers) {
      await runCommand("uci add_list dhcp.@dnsmasq[0].server='$s'");
    }
    await runCommand('uci commit dhcp; /etc/init.d/dnsmasq restart');
  }

  Future<Map<String, bool>> installPackagesWithProgress(List<String> packages, void Function(String pkg, String status) onProgress) async {
    final pkg = await detectPackageManager();
    final result = <String, bool>{};
    for (final name in packages) {
      onProgress(name, 'downloading');
      try {
        if (pkg == 'APK') {
          await runCommand('apk add \$name');
        } else {
          await runCommand('opkg install \$name');
        }
        onProgress(name, 'done');
        result[name] = true;
      } catch (_) {
        onProgress(name, 'error');
        result[name] = false;
      }
    }
    return result;
  }

  Future<String?> checkFirmwareUpdate() async {
    try {
      final raw = await runCommand('auc -c 2>&1 || echo "NO_AUC"');
      if (raw.contains('NO_AUC') || raw.contains('not found')) {
        // Пробуем через LuCI ubus
        try {
          final luci = await runCommand('ubus call luci-rpc getAttendedSysupgrade 2>/dev/null || echo ""');
          if (luci.isNotEmpty && !luci.contains('not found')) {
            return 'Найдено обновление (LuCI). Установите: opkg install attendedsysupgrade-common';
          }
        } catch (_) {}
        return 'Установите: opkg install attendedsysupgrade-common';
      }
      // Парсим вывод auc
      if (raw.contains('No upgrade available') || raw.contains('already up to date')) return null;
      if (raw.contains('Upgrade to')) {
        final lines = LineSplitter.split(raw).where((l) => l.isNotEmpty).toList();
        return lines.join('\n').trim();
      }
      // Если auc молчит или дал ошибку
      return raw.trim().isNotEmpty ? raw.trim() : 'Проверьте интернет на роутере';
    } catch (_) {
      return 'Ошибка проверки. Установите: opkg install auc';
    }
  }

  Future<String> upgradeFirmware(void Function(String) onProgress) async {
    onProgress('checking');
    final check = await runCommand('which auc 2>/dev/null || echo "NOT_FOUND"');
    if (check.contains('NOT_FOUND')) {
      onProgress('installing_auc');
      await runCommand('opkg update && opkg install auc');
    }
    onProgress('downloading');
    await runCommand('auc -y -b 0 -r 2>&1 || echo "FAIL"');
    onProgress('rebooting');
    return 'Роутер перезагружается...';
  }

  static const russianProviders = {
    'beeline': {'name': 'Билайн', 'proto': 'dhcp', 'desc': 'DHCP — автоматически'},
    'rostelecom': {'name': 'Ростелеком', 'proto': 'pppoe', 'desc': 'PPPoE — логин и пароль из договора'},
    'ttk': {'name': 'ТТК', 'proto': 'pppoe', 'desc': 'PPPoE — логин@ttk, пароль из договора'},
    'mgts': {'name': 'МГТС', 'proto': 'pppoe', 'desc': 'PPPoE — номер договора, пароль'},
    'domru': {'name': 'Дом.ру', 'proto': 'dhcp', 'desc': 'DHCP — автоматически'},
    'yota': {'name': 'Yota', 'proto': 'dhcp', 'desc': 'DHCP — автоматически'},
    'atel': {'name': 'Атель', 'proto': 'pppoe', 'desc': 'PPPoE — логин и пароль'},
    'mts': {'name': 'МТС', 'proto': 'dhcp', 'desc': 'DHCP или PPPoE по необходимости'},
  };

  Future<void> configureWan(String providerKey, {String? username, String? password}) async {
    final p = russianProviders[providerKey];
    if (p == null) throw Exception('Провайдер не найден');
    final proto = p['proto']!;

    if (proto == 'dhcp') {
      await runCommand('''
uci set network.wan=interface
uci set network.wan.proto='dhcp'
uci set network.wan.device='br-wan' 2>/dev/null || uci set network.wan.device='eth1'
uci commit network
/etc/init.d/network reload
''');
    } else if (proto == 'pppoe' && username != null && password != null) {
      await runCommand("""
uci set network.wan=interface
uci set network.wan.proto='pppoe'
uci set network.wan.device='br-wan' 2>/dev/null || uci set network.wan.device='eth1'
uci set network.wan.username='${username.replaceAll("'", "'\\''")}'
uci set network.wan.password='${password.replaceAll("'", "'\\''")}'
uci commit network
/etc/init.d/network reload
""");
    } else {
      throw Exception('PPPoE требует логин и пароль');
    }
  }

  Future<List<Map<String, String>>> scanNearbyWifi(String device) async {
    // Ищем ВСЕ WiFi-интерфейсы и находим тот, что привязан к нашему radio
    String iface = device;
    try {
      final raw = await runCommand('iw dev 2>/dev/null || echo ""');
      final lines = LineSplitter.split(raw).toList();
      // Ищем phy для device (radio0 → phy0, radio1 → phy1)
      final phyNum = device.replaceAll(RegExp(r'[^0-9]'), '');
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].contains('Interface')) {
          final name = lines[i].replaceAll('Interface', '').trim();
          // Проверяем к какому phy привязан этот интерфейс
          try {
            final phyInfo = await runCommand('iw dev $name info 2>/dev/null | grep wiphy || echo ""');
            if (phyInfo.contains('wiphy $phyNum')) {
              iface = name;
              break;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    // Если не нашли - пробуем iwinfo напрямую (device может быть уже правильным именем)
    final raw = await runCommand('iwinfo $iface scan 2>/dev/null || iw dev $iface scan 2>/dev/null | grep -E "SSID:|signal:|ESSID:" || echo ""');
    final networks = <Map<String, String>>[];
    String? currentSsid, currentSig, currentCh;

    for (final line in LineSplitter.split(raw)) {
      final trimmed = line.trim();
      if (trimmed.startsWith('ESSID:') || trimmed.startsWith('SSID:')) {
        if (currentSsid != null) {
          networks.add({'ssid': currentSsid, 'signal': currentSig ?? '-', 'channel': currentCh ?? '-'});
        }
        currentSsid = trimmed.substring(trimmed.indexOf(':') + 1).trim().replaceAll('"', '').replaceAll("'", '');
        currentSig = null; currentCh = null;
      }
      final sigMatch = RegExp(r'signal:\s*(-?\d+)', caseSensitive: false).firstMatch(trimmed);
      if (sigMatch != null) currentSig = sigMatch.group(1);
      final chMatch = RegExp(r'Channel:\s*(\d+)', caseSensitive: false).firstMatch(trimmed);
      if (chMatch != null) currentCh = chMatch.group(1);
    }
    if (currentSsid != null && currentSsid.isNotEmpty) {
      networks.add({'ssid': currentSsid, 'signal': currentSig ?? '-', 'channel': currentCh ?? '-'});
    }
    return networks;
  }

  Future<void> wifiClientConnect(String device, String ssid, String? password) async {
    final esc = (String s) => s.replaceAll("'", "'\\''").replaceAll('"', '\\"');
    if (password != null && password.isNotEmpty) {
      await runCommand("""
uci add wireless wifi-iface 2>/dev/null || true
uci set wireless.@wifi-iface[-1].device='${esc(device)}'
uci set wireless.@wifi-iface[-1].mode='sta'
uci set wireless.@wifi-iface[-1].ssid='${esc(ssid)}'
uci set wireless.@wifi-iface[-1].encryption='psk2'
uci set wireless.@wifi-iface[-1].key='${esc(password)}'
uci set wireless.@wifi-iface[-1].network='wan'
uci commit wireless
wifi reload
""");
    } else {
      await runCommand("""
uci add wireless wifi-iface 2>/dev/null || true
uci set wireless.@wifi-iface[-1].device='${esc(device)}'
uci set wireless.@wifi-iface[-1].mode='sta'
uci set wireless.@wifi-iface[-1].ssid='${esc(ssid)}'
uci set wireless.@wifi-iface[-1].encryption='none'
uci set wireless.@wifi-iface[-1].network='wan'
uci commit wireless
wifi reload
""");
    }
  }

  Future<Map<String, dynamic>> aiOptimizeWifi(String device, {List<ChannelScanResult>? phoneScans}) async {
    final scan = await scanWifiChannels(device);
    final allCh = await getAvailableChannels(device);
    final hts = await getAvailableHtModes(device);
    final band = await runCommand('uci get wireless.$device.band 2>/dev/null || echo "2.4g"').then((s) => s.trim());

    // Определяем какие каналы реально заняты с учётом ширины
    final occupied = <int, int>{}; // канал -> вес помех

    // Данные с роутера
    for (final entry in scan.entries) {
      final ch = entry.key;
      final count = entry.value;
      // Соседние каналы тоже учитываем (co-channel interference)
      for (int c = ch - 2; c <= ch + 2; c++) {
        if (c >= 1) occupied[c] = (occupied[c] ?? 0) + count;
      }
    }

    // Данные с телефона (если есть)
    if (phoneScans != null) {
      for (final ps in phoneScans) {
        for (final ch in ps.occupiedChannels) {
          occupied[ch] = (occupied[ch] ?? 0) + 2; // телефон = больший вес
        }
        // Сигнал > -50dBm = очень сильный сигнал = больше помех
        if (ps.signalStrength > -50) {
          for (final ch in ps.occupiedChannels) {
            occupied[ch] = (occupied[ch] ?? 0) + 2;
          }
        }
      }
    }

    final result = <String, dynamic>{
      'channels': scan,
      'available_channels': allCh,
      'available_ht_modes': hts,
      'phone_scans': phoneScans?.length ?? 0,
    };

    // Выбираем лучший канал
    int? bestCh;
    int bestScore = 999999;
    for (final ch in allCh) {
      final score = occupied[ch] ?? 0;
      if (score < bestScore) {
        bestScore = score;
        bestCh = ch;
      }
    }

    // Выбираем лучшую ширину канала
    String bestHt = hts.isNotEmpty ? hts[0] : 'HT20';
    final is5G = band == '5g' || band == '6g';
    final maxNoise = occupied.values.isEmpty ? 0 : occupied.values.reduce((a, b) => a > b ? a : b);

    if (is5G) {
      // Для 5GHz: если эфир чистый, используем HE160, если немного зашумлён — HE80, иначе HE40
      if (maxNoise <= 2 && hts.any((h) => h.contains('160'))) {
        bestHt = hts.firstWhere((h) => h.contains('160'), orElse: () => hts.firstWhere((h) => h.contains('80'), orElse: () => hts[0]));
      } else if (maxNoise <= 5 && hts.any((h) => h.contains('80'))) {
        bestHt = hts.firstWhere((h) => h.contains('80') && !h.contains('160'), orElse: () => hts[0]);
      } else if (maxNoise <= 10 && hts.any((h) => h.contains('40'))) {
        bestHt = hts.firstWhere((h) => h.contains('40') && !h.contains('80') && !h.contains('160'), orElse: () => hts[0]);
      } else {
        bestHt = hts.contains('HT20') ? 'HT20' : hts[0];
      }
    } else {
      // Для 2.4GHz: максимум HT40 (и то, если эфир чистый)
      if (maxNoise <= 3 && hts.any((h) => h.contains('40'))) {
        bestHt = hts.firstWhere((h) => h.contains('40') && !h.contains('80'), orElse: () => hts[0]);
      } else {
        bestHt = 'HT20';
      }
    }

    result['recommended_channel'] = bestCh;
    result['recommended_htmode'] = bestHt;
    result['interference_level'] = bestScore;
    result['max_noise'] = maxNoise;
    result['band'] = band;
    return result;
  }

  Future<List<Map<String, String>>> fetchStaticLeases() async {
    final raw = await runCommand('uci show dhcp 2>/dev/null | grep -E "^dhcp\\.@host\\[|dhcp\\.[^. ]+=host" || echo ""');
    final result = <Map<String, String>>[];
    final sectionLines = <String, String>{};
    for (final line in LineSplitter.split(raw)) {
      if (line.contains('=host')) {
        final m = RegExp(r'^dhcp\.([^=]+)=host').firstMatch(line);
        if (m != null) sectionLines[m.group(1)!] = '';
      }
    }
    for (final section in sectionLines.keys) {
      try {
        final name = await runCommand('uci get dhcp.$section.name 2>/dev/null || echo ""');
        final mac = await runCommand('uci get dhcp.$section.mac 2>/dev/null || echo ""');
        final ip = await runCommand('uci get dhcp.$section.ip 2>/dev/null || echo ""');
        if (mac.trim().isNotEmpty && ip.trim().isNotEmpty) {
          result.add({'section': section, 'name': name.trim(), 'mac': mac.trim().toLowerCase(), 'ip': ip.trim()});
        }
      } catch (_) {}
    }
    return result;
  }

  Future<void> setStaticLease({required String mac, required String ip, String? hostname}) async {
    final cleanMac = mac.toLowerCase();
    final esc = (String s) => s.replaceAll("'", "'\\''");
    final name = hostname ?? mac;

    // Удаляем старый lease если есть
    final existing = await fetchStaticLeases();
    for (final e in existing) {
      if (e['mac'] == cleanMac) {
        await runCommand('uci delete dhcp.${e['section']}');
      }
    }

    await runCommand("""
uci add dhcp host
uci set dhcp.@host[-1].name='${esc(name)}'
uci set dhcp.@host[-1].mac='${cleanMac}'
uci set dhcp.@host[-1].ip='${esc(ip)}'
uci commit dhcp
/etc/init.d/dnsmasq restart
""");
  }

  Future<void> removeStaticLease(String mac) async {
    final cleanMac = mac.toLowerCase();
    final existing = await fetchStaticLeases();
    for (final e in existing) {
      if (e['mac'] == cleanMac) {
        await runCommand('uci delete dhcp.${e['section']}; uci commit dhcp; /etc/init.d/dnsmasq restart');
        return;
      }
    }
  }

  Future<void> applySpeedLimit(String mac, int kbps) async {
    final cleanMac = mac.toLowerCase();
    // Удаляем старые правила
    await runCommand('nft delete rule inet fw4 forward ether saddr $cleanMac handle 2>/dev/null || true');
    await runCommand('nft add table inet fw4_qos 2>/dev/null || true');
    await runCommand('nft add chain inet fw4_qos forward { type filter hook forward priority -1\\; } 2>/dev/null || true');
    if (kbps <= 0) return;
    await runCommand('nft add rule inet fw4_qos forward ether saddr $cleanMac limit rate over $kbps kbytes/second drop 2>/dev/null || true');
  }

  Future<void> scheduleBlock(String mac, {String? startTime, String? stopTime, List<int>? days}) async {
    final cleanMac = mac.toLowerCase();
    if (startTime != null && stopTime != null) {
      // NFTables time match: "HH:MM-HH:MM" format
    }
    // Проще через cron: добавляем задания iptables по расписанию
    if (startTime != null && stopTime != null) {
      final startH = startTime.split(':').first;
      final startM = startTime.split(':').last;
      final stopH = stopTime.split(':').first;
      final stopM = stopTime.split(':').last;

      await runCommand('''
echo "$startM $startH * * * nft add element inet fw4 blocklist { $cleanMac } 2>/dev/null" >> /etc/crontabs/root
echo "$stopM $stopH * * * nft delete element inet fw4 blocklist { $cleanMac } 2>/dev/null" >> /etc/crontabs/root
/etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true
''');
    }
  }

  Future<void> removeScheduleBlock(String mac) async {
    await runCommand("sed -i '/$mac/d' /etc/crontabs/root; /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || true");
  }

  Future<String> fetchMacVendor(String mac) async {
    try {
      final prefix = mac.replaceAll(':', '').substring(0, 6).toLowerCase();
      final raw = await runCommand('wget -qO- --timeout=3 https://api.macvendors.com/$prefix 2>/dev/null || echo ""');
      return raw.trim().isNotEmpty ? raw.trim() : 'Неизвестно';
    } catch (_) {
      return mac;
    }
  }

  Future<String> classifyDevice({required String mac, String? hostname, String? ip}) async {
    final vendor = await fetchMacVendor(mac);
    final host = (hostname ?? '').toLowerCase();

    // Определяем по имени хоста
    if (host.contains('iphone') || host.contains('ipad')) return 'iPhone/iPad';
    if (host.contains('android') || host.contains('samsung')) return 'Телефон Android';
    if (host.contains('macbook') || host.contains('imac') || host.contains('mac-')) return 'Mac';
    if (host.contains('windows') || host.contains('desktop-') || host.contains('pc')) return 'ПК Windows';
    if (host.contains('xbox')) return 'Xbox';
    if (host.contains('playstation') || host.contains('ps4') || host.contains('ps5')) return 'PlayStation';
    if (host.contains('nintendo') || host.contains('switch')) return 'Nintendo Switch';
    if (host.contains('tv') || host.contains('bravia') || host.contains('lg') || host.contains('samsungtv')) return 'Smart TV';
    if (host.contains('chromecast') || host.contains('google-home') || host.contains('nest')) return 'Google Home';
    if (host.contains('alexa') || host.contains('echo')) return 'Amazon Echo';
    if (host.contains('xiaomi') || host.contains('yeelink')) return 'Умное устройство Xiaomi';
    if (host.contains('camera') || host.contains('ipcam')) return 'IP-камера';
    if (host.contains('printer')) return 'Принтер';
    if (host.contains('raspberry')) return 'Raspberry Pi';
    if (host.contains('openwrt')) return 'Роутер OpenWrt';

    // Определяем по MAC-вендору
    final v = vendor.toLowerCase();
    if (v.contains('apple')) {
      if (host.contains('iphone') || host.contains('ipad')) return 'iPhone/iPad';
      return 'Apple (Mac/iPhone)';
    }
    if (v.contains('samsung')) return host.contains('tv') ? 'Samsung TV' : 'Samsung';
    if (v.contains('xiaomi')) return 'Xiaomi';
    if (v.contains('huawei')) return 'Huawei';
    if (v.contains('sony')) return 'Sony (TV/PlayStation)';
    if (v.contains('lg')) return 'LG (TV/телефон)';
    if (v.contains('google')) return 'Google';
    if (v.contains('amazon')) return 'Amazon';
    if (v.contains('microsoft')) return 'Microsoft (Xbox/ПК)';
    if (v.contains('nintendo')) return 'Nintendo';
    if (v.contains('tplink') || v.contains('tp-link')) return 'TP-Link';
    if (v.contains('asus')) return 'ASUS';
    if (v.contains('cisco') || v.contains('linksys') || v.contains('d-link') || v.contains('netgear')) return 'Сетевое устройство';
    if (v.contains('raspberry')) return 'Raspberry Pi';
    if (v.contains('intel') || v.contains('dell') || v.contains('lenovo') || v.contains('hp')) return 'ПК/Ноутбук';
    if (v.contains('espressif') || v.contains('arduino')) return 'IoT/ESP';
    if (v.contains('broadcom') || v.contains('qualcomm')) return 'Чипсет';
    if (v.contains('nvidia')) return 'NVIDIA Shield';

    // Если есть IP, пробуем OS fingerprinting по портам
    if (ip != null && ip != '-' && ip != '0.0.0.0') {
      try {
        final ports = await runCommand('timeout 3 nmap -sS -F --top-ports 50 -T4 $ip 2>/dev/null | grep open || echo ""');
        final openPorts = ports.split('\n').map((l) => l.trim()).where((l) => l.contains('open')).join('\n');
        if (openPorts.contains('port 21') || openPorts.contains('22/tcp') || openPorts.contains('23/tcp')) return 'Linux/OpenWrt';
        if (openPorts.contains('554/tcp') || openPorts.contains('37777/tcp')) return 'IP-камера';
        if (openPorts.contains('9100/tcp')) return 'Принтер';
        if (openPorts.contains('3389/tcp') || openPorts.contains('445/tcp') || openPorts.contains('139/tcp')) return 'ПК Windows';
        if (openPorts.contains('62078/tcp')) return 'iPhone (синхронизация)';
        if (openPorts.contains('5357/tcp') || openPorts.contains('903/tcp')) return 'Windows';
        if (openPorts.contains('1900/tcp') || openPorts.contains('1900/udp')) return 'UPnP устройство';
        if (openPorts.contains('53/tcp')) return 'DNS-сервер';
      } catch (_) {}
    }

    // Stryker-style: проверяем специфичные порты через /proc/net/tcp на роутере
    if (ip != null && ip != '-') {
      try {
        final conntrack = await runCommand('conntrack -L 2>/dev/null | grep "$ip" | awk \'{print \$5}\' | sort -u | head -10 || echo ""');
        if (conntrack.contains('554') || conntrack.contains('37777')) return 'IP-камера';
        if (conntrack.contains('9100')) return 'Принтер';
        if (conntrack.contains('3389')) return 'ПК Windows';
      } catch (_) {}
    }

    return vendor.isEmpty || vendor == 'Неизвестно' ? 'Устройство' : vendor;
  }

  Future<String> fetchTemperature() async {
    try {
      for (final p in ['/sys/class/thermal/thermal_zone0/temp', '/sys/class/hwmon/hwmon0/temp1_input', '/sys/class/thermal/thermal_zone1/temp']) {
        final r = await runCommand('cat $p 2>/dev/null && echo "FOUND" || echo ""');
        if (r.contains('FOUND')) {
          final temp = int.tryParse(r.replaceAll('FOUND', '').trim()) ?? 0;
          final c = temp > 1000 ? temp / 1000.0 : temp.toDouble();
          return '${c.toStringAsFixed(1)} °C';
        }
      }
      return 'Датчик не найден';
    } catch (_) {
      return 'Ошибка';
    }
  }

  Future<Map<String, int>> fetchVnstatTraffic() async {
    try {
      final raw = await runCommand('vnstat --json m 2>/dev/null || echo "{}"');
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final interfaces = data['interfaces'] as List<dynamic>? ?? [];
      int rx = 0, tx = 0;
      if (interfaces.isNotEmpty) {
        final iface = interfaces[0] as Map<String, dynamic>;
        final traffic = iface['traffic'] as Map<String, dynamic>? ?? {};
        rx = int.tryParse(traffic['rx']?.toString() ?? '0') ?? 0;
        tx = int.tryParse(traffic['tx']?.toString() ?? '0') ?? 0;
      }
      return {'rx': rx, 'tx': tx, 'total': rx + tx};
    } catch (_) {
      return {'rx': 0, 'tx': 0, 'total': 0};
    }
  }

  static const Map<String, String> nmapProfiles = {
    'quick': '-sn -PE -n',
    'fast': '-sS -F --top-ports 100 -T4',
    'standard': '-sV -T4',
    'full': '-sV -p- -T4 -v',
    'intense': '-O -sV -sC -A -T4 -v',
    'udp': '-sU -F --top-ports 50',
  };

  Future<List<Map<String, String>>> runNmapScan({String target = '192.168.1.0/24', String profile = 'quick'}) async {
    final flags = nmapProfiles[profile] ?? nmapProfiles['quick']!;
    final raw = await runCommand('nmap $target $flags 2>/dev/null || echo ""');
    final result = <Map<String, String>>[];
    String? ip, mac, vendor;
    for (final line in LineSplitter.split(raw)) {
      if (line.contains('Nmap scan report for')) {
        if (ip != null) result.add({'ip': ip, 'mac': mac ?? '?', 'vendor': vendor ?? '?'});
        ip = line.split(' ').last;
        mac = null; vendor = null;
      }
      if (line.contains('MAC Address:')) {
        final parts = line.split('MAC Address:')[1].trim().split(' (');
        mac = parts[0];
        vendor = parts.length > 1 ? parts[1].replaceAll(')', '') : '?';
      }
    }
    if (ip != null) result.add({'ip': ip, 'mac': mac ?? '?', 'vendor': vendor ?? '?'});
    return result;
  }

  Future<List<Map<String, String>>> fetchDdnsStatus() async {
    final result = <Map<String, String>>[];
    try {
      final raw = await runCommand('uci show ddns 2>/dev/null | grep "=service" || echo ""');
      for (final line in LineSplitter.split(raw)) {
        final m = RegExp(r'^ddns\.([^=]+)=service').firstMatch(line);
        if (m == null) continue;
        final s = m.group(1)!;
        try {
          result.add({
            'section': s,
            'name': (await runCommand('uci get ddns.$s.service_name 2>/dev/null || echo "-"')).trim(),
            'domain': (await runCommand('uci get ddns.$s.domain 2>/dev/null || echo "-"')).trim(),
            'ip': (await runCommand('uci get ddns.$s.ip_source 2>/dev/null || echo "web"')).trim(),
          });
        } catch (_) {}
      }
    } catch (_) {}
    return result;
  }

  Future<String> fetchAdGuardStatus() async {
    try {
      return await runCommand('curl -s http://127.0.0.1:3000/control/status 2>/dev/null | jsonfilter -e "@.protection_enabled" 2>/dev/null || echo "NOT_RUNNING"');
    } catch (_) {
      return 'NOT_RUNNING';
    }
  }

  Future<List<Map<String, String>>> fetchUsbDevices() async {
    final result = <Map<String, String>>[];
    try {
      final raw = await runCommand('lsblk -o NAME,SIZE,MOUNTPOINT,LABEL 2>/dev/null || block info 2>/dev/null || echo ""');
      for (final line in LineSplitter.split(raw)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts[0] != 'NAME') {
          result.add({
            'name': parts[0],
            'size': parts.length > 1 ? parts[1] : '?',
            'mount': parts.length > 2 ? parts[2] : '—',
          });
        }
      }
    } catch (_) {}
    return result;
  }

  Future<List<Map<String, String>>> fetchPortForwards() async {
    final raw = await runCommand('uci show firewall 2>/dev/null | grep "=redirect" || echo ""');
    final result = <Map<String, String>>[];
    for (final line in LineSplitter.split(raw)) {
      final match = RegExp(r'^firewall\.([^=]+)=redirect').firstMatch(line);
      if (match == null) continue;
      final s = match.group(1)!;
      try {
        result.add({
          'section': s,
          'name': (await runCommand('uci get firewall.$s.name 2>/dev/null || echo "-"')).trim(),
          'proto': (await runCommand('uci get firewall.$s.proto 2>/dev/null || echo "tcp"')).trim(),
          'dport': (await runCommand('uci get firewall.$s.src_dport 2>/dev/null || echo "-"')).trim(),
          'ip': (await runCommand('uci get firewall.$s.dest_ip 2>/dev/null || echo "-"')).trim(),
          'dp': (await runCommand('uci get firewall.$s.dest_port 2>/dev/null || echo "-"')).trim(),
        });
      } catch (_) {}
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> fetchTopology() async {
    final result = <Map<String, dynamic>>[];
    // ARP таблица
    try {
      final arp = await runCommand('cat /proc/net/arp 2>/dev/null | tail -n +2 || echo ""');
      for (final line in LineSplitter.split(arp)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 4) {
          result.add({'ip': parts[0], 'mac': parts[3].toLowerCase(), 'iface': parts[5], 'type': 'arp'});
        }
      }
    } catch (_) {}

    // DHCP leases
    try {
      final dhcp = await runCommand('cat /tmp/dhcp.leases 2>/dev/null || echo ""');
      for (final line in LineSplitter.split(dhcp)) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 4) {
          final existing = result.indexWhere((e) => e['mac'] == parts[1].toLowerCase());
          if (existing >= 0) {
            result[existing]['hostname'] = parts[3];
            result[existing]['type'] = 'dhcp';
          } else {
            result.add({'ip': parts[2], 'mac': parts[1].toLowerCase(), 'hostname': parts[3], 'type': 'dhcp'});
          }
        }
      }
    } catch (_) {}

    // LLDP соседи (другие роутеры/свитчи)
    try {
      final lldp = await runCommand('which lldpcli 2>/dev/null && lldpcli show neighbors 2>/dev/null || echo ""');
      if (lldp.isNotEmpty) {
        final currentDevice = <String, String>{};
        for (final line in LineSplitter.split(lldp)) {
          if (line.contains('ChassisID:')) currentDevice['mac'] = line.split(':').last.trim().toLowerCase();
          if (line.contains('SysName:')) currentDevice['name'] = line.split(':').last.trim();
          if (line.contains('PortDescr:')) {
            currentDevice['port'] = line.split(':').last.trim();
            if (currentDevice['mac'] != null) {
              result.add(Map<String, dynamic>.from(currentDevice)..['type'] = 'router');
              currentDevice.clear();
            }
          }
        }
      }
    } catch (_) {}

    return result;
  }

  Future<List<ClientInfo>> fetchClients({bool withTraffic = false}) async {
    // OpenWrt 24.10 не всегда имеет ubus call dhcp lease, поэтому парсим файл leases
    final raw = await runCommand('cat /tmp/dhcp.leases 2>/dev/null || echo ""');
    final leases = <ClientInfo>[];
    for (final line in LineSplitter.split(raw)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 4) continue;
      final expiry = int.tryParse(parts[0]);
      leases.add(ClientInfo(
        hostname: parts[3].isNotEmpty ? parts[3] : parts[1],
        mac: parts[1].toLowerCase(),
        ip: parts[2],
        leaseExpiry: expiry,
        active: true,
      ));
    }
    return leases;
  }

  Future<List<PackageInfo>> fetchInstalledPackages() async {
    final raw = await runCommand('opkg list-installed');
    return _parsePackages(raw, installed: true);
  }

  Future<List<PackageInfo>> searchPackages(String query) async {
    if (query.isEmpty) return [];
    final raw = await runCommand('opkg list | grep -i "${query.replaceAll("\"", "")}" | head -50');
    return _parsePackages(raw, installed: false);
  }

  List<PackageInfo> _parsePackages(String raw, {required bool installed}) {
    final List<PackageInfo> list = [];
    for (final line in LineSplitter.split(raw)) {
      final parts = line.split(' - ');
      if (parts.length < 2) continue;
      list.add(PackageInfo(
        name: parts[0].trim(),
        version: parts[1].trim(),
        description: parts.length > 2 ? parts[2].trim() : null,
        installed: installed,
      ));
    }
    return list;
  }

  Future<String> installPackage(String name) async {
    return runCommand('opkg install $name');
  }

  Future<String> removePackage(String name) async {
    return runCommand('opkg remove $name');
  }

  Future<String> updatePackageLists() async {
    return runCommand('opkg update');
  }

  Future<void> reboot() async {
    await runCommand('reboot');
  }

  /// Генерация SSH-ключей на роутере и установка публичного ключа
  Future<Map<String, String>> generateAndInstallKey() async {
    // 1. Генерируем ED25519 ключ (без пароля)
    await runCommand('rm -f /tmp/id_ed25519 /tmp/id_ed25519.pub; ssh-keygen -t ed25519 -f /tmp/id_ed25519 -N "" 2>/dev/null');
    // 2. Читаем приватный ключ
    final privKey = await runCommand('cat /tmp/id_ed25519');
    // 3. Читаем публичный ключ
    final pubKey = await runCommand('cat /tmp/id_ed25519.pub');
    // 4. Устанавливаем публичный ключ в authorized_keys
    await runCommand('mkdir -p /etc/dropbear && cat /tmp/id_ed25519.pub >> /etc/dropbear/authorized_keys');
    await runCommand('mkdir -p /root/.ssh 2>/dev/null; cat /tmp/id_ed25519.pub >> /root/.ssh/authorized_keys 2>/dev/null || true');
    // 5. Удаляем временные файлы
    await runCommand('rm -f /tmp/id_ed25519 /tmp/id_ed25519.pub');
    return {'private': privKey, 'public': pubKey};
  }

  Future<String> syncTime() async {
    // Пробуем несколько методов синхронизации времени
    try {
      // Метод 1: ntpd однократно
      final r1 = await runCommand(
        'ntpd -n -q -p 0.pool.ntp.org 2>&1 || ntpd -q -p 0.pool.ntp.org 2>&1 || echo FAIL'
      ).timeout(const Duration(seconds: 15));
      if (!r1.contains('FAIL') && !r1.contains('not found')) {
        final curTime = await runCommand('date "+%Y-%m-%d %H:%M:%S"').then((s) => s.trim());
        return 'Время синхронизировано: $curTime';
      }
    } catch (_) {}

    try {
      // Метод 2: sysntpd restart
      final r2 = await runCommand(
        '/etc/init.d/sysntpd restart 2>&1 || echo FAIL'
      ).timeout(const Duration(seconds: 10));
      if (!r2.contains('FAIL') && !r2.contains('not found')) {
        await Future.delayed(const Duration(seconds: 2));
        final curTime = await runCommand('date "+%Y-%m-%d %H:%M:%S"').then((s) => s.trim());
        return 'Время синхронизировано: $curTime';
      }
    } catch (_) {}

    try {
      // Метод 3: установка времени через HTTP
      final httpTime = await runCommand(
        "date -s \"\$(wget -qO- -T 3 http://worldtimeapi.org/api/ip 2>/dev/null | grep -o '\\\"datetime\\\":\\\"[^\\\"]*' | cut -d'\"' -f4)\" 2>&1 || echo FAIL"
      ).timeout(const Duration(seconds: 10));
      if (!httpTime.contains('FAIL')) {
        return 'Время установлено через HTTP';
      }
    } catch (_) {}

    return 'Не удалось синхронизировать. Установите: opkg install ntpdate';
  }

  Future<void> wifiReload() async {
    await runCommand('wifi reload');
  }

  Future<Map<String, double>> fetchCpuMemoryStats() async {
    final raw = await runCommand('ubus call system info');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final info = data['info'] ?? data;
    final memory = info['memory'] ?? {};
    final total = (memory['total'] ?? 0) is int ? memory['total'] as int : 0;
    final free = (memory['free'] ?? 0) is int ? memory['free'] as int : 0;
    final used = total - free;
    return {
      'memoryTotal': total.toDouble(),
      'memoryUsed': used.toDouble(),
      'cpuLoad': ((info['load'] is List && (info['load'] as List).isNotEmpty)
              ? ((info['load'] as List)[0] as num).toDouble() / 65536.0
              : 0.0),
    };
  }

  Future<List<NetworkInterface>> fetchNetworkInterfaces() async {
    final raw = await runCommand('ubus call network.interface dump');
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final interfaces = data['interface'] as List<dynamic>? ?? [];
    return interfaces
        .whereType<Map<String, dynamic>>()
        .map((i) => NetworkInterface.fromUbusJson(i['interface']?.toString() ?? 'unknown', i))
        .toList();
  }

  Future<List<VpnInterface>> fetchVpnStatus() async {
    final List<VpnInterface> result = [];

    // Читаем интерфейсы VPN из network
    try {
      final raw = await runCommand('uci show network 2>/dev/null | grep -E "^network\\.[^=]+=interface" || echo ""');
      final sections = <String>{};
      for (final line in LineSplitter.split(raw)) {
        final match = RegExp(r'^network\.([^=]+)=interface').firstMatch(line);
        if (match != null) sections.add(match.group(1)!);
      }

      for (final section in sections) {
        try {
          final proto = await runCommand('uci get network.$section.proto 2>/dev/null || echo ""');
          final p = proto.trim();
          if (p == 'wireguard' || p == 'amneziawg') {
            final up = await runCommand('ifstatus $section 2>/dev/null | jsonfilter -e "@.up" || echo "false"');
            final typeName = p == 'amneziawg' ? 'AmneziaWG' : 'WireGuard';
            result.add(VpnInterface(
              name: section,
              type: typeName,
              up: up.trim() == 'true',
              device: section,
              enabled: true,
            ));
          }
        } catch (_) {}
      }
    } catch (_) {}

    // OpenVPN конфиги
    try {
      final raw = await runCommand('uci show openvpn 2>/dev/null || echo ""');
      final sections = <String>{};
      for (final line in LineSplitter.split(raw)) {
        final match = RegExp(r'^openvpn\.([^=]+)=').firstMatch(line);
        if (match != null) sections.add(match.group(1)!);
      }
      for (final section in sections) {
        final enabled = await runCommand('uci get openvpn.$section.enabled 2>/dev/null || echo "1"');
        final running = await runCommand('/etc/init.d/openvpn running $section 2>/dev/null && echo 1 || echo 0');
        result.add(VpnInterface(
          name: section,
          type: 'OpenVPN',
          up: running.trim() == '1',
          device: section,
          enabled: enabled.trim() != '0',
        ));
      }
    } catch (_) {}

    return result;
  }

  Future<void> vpnUp(String name) async {
    await runCommand('ifup $name 2>/dev/null || /etc/init.d/openvpn start $name 2>/dev/null || true');
  }

  Future<void> addL2tpClient({required String name, required String server, required String username, required String password, String? secret}) async {
    final esc = (String s) => s.replaceAll("'", "'\\''");
    await runCommand('opkg list-installed | grep -q xl2tpd || opkg install xl2tpd resolveip');
    await runCommand("""
uci set network.${esc(name)}=interface
uci set network.${esc(name)}.proto='l2tp'
uci set network.${esc(name)}.server='${esc(server)}'
uci set network.${esc(name)}.username='${esc(username)}'
uci set network.${esc(name)}.password='${esc(password)}'
${secret != null ? "uci set network.${esc(name)}.ipsec_secret='${esc(secret)}'" : ""}
uci set network.${esc(name)}.ipsec_demand='1'
uci set network.${esc(name)}.defaultroute='0'
uci commit network
/etc/init.d/network reload
""");
  }

  Future<void> addPptpClient({required String name, required String server, required String username, required String password}) async {
    final esc = (String s) => s.replaceAll("'", "'\\''");
    await runCommand('opkg list-installed | grep -q pptp || opkg install pptp');
    await runCommand("""
uci set network.${esc(name)}=interface
uci set network.${esc(name)}.proto='pptp'
uci set network.${esc(name)}.server='${esc(server)}'
uci set network.${esc(name)}.username='${esc(username)}'
uci set network.${esc(name)}.password='${esc(password)}'
uci commit network
/etc/init.d/network reload
""");
  }

  Future<void> routeAllThroughVpn(String vpnInterface) async {
    await runCommand('''
uci set network.${vpnInterface}.defaultroute='1'
uci delete network.${vpnInterface}.peerdns 2>/dev/null || true
uci commit network
/etc/init.d/network reload
''');
  }

  Future<void> addSstpClient({required String name, required String server, required String username, required String password}) async {
    final esc = (String s) => s.replaceAll("'", "'\\''");
    await runCommand('opkg list-installed | grep -q sstp-client || opkg install sstp-client');
    await runCommand("uci set network.$name=interface; uci set network.$name.proto='sstp'; uci set network.$name.server='${esc(server)}'; uci set network.$name.username='${esc(username)}'; uci set network.$name.password='${esc(password)}'; uci set network.$name.defaultroute='0'; uci commit network; /etc/init.d/network reload");
  }

  Future<void> addIpsecClient({required String name, required String server, required String username, required String password, required String psk}) async {
    final esc = (String s) => s.replaceAll("'", "'\\''");
    await runCommand('opkg list-installed | grep -q strongswan || opkg install strongswan-default');
    await runCommand("uci set network.$name=interface; uci set network.$name.proto='ipsec'; uci set network.$name.server='${esc(server)}'; uci set network.$name.username='${esc(username)}'; uci set network.$name.password='${esc(password)}'; uci set network.$name.ipsec_psk='${esc(psk)}'; uci commit network; /etc/init.d/network reload");
  }

  Future<void> importOpenvpnConfig({required String name, required String ovpnContent}) async {
    final b64 = base64Encode(utf8.encode(ovpnContent));
    await runCommand('opkg list-installed | grep -q openvpn || opkg install openvpn-openssl');
    await runCommand("echo '$b64' | base64 -d > /etc/openvpn/$name.ovpn; uci set openvpn.$name=openvpn; uci set openvpn.$name.enabled='1'; uci set openvpn.$name.config='/etc/openvpn/$name.ovpn'; uci commit openvpn; /etc/init.d/openvpn start $name 2>/dev/null || true");
  }

  Future<void> vpnDown(String name) async {
    await runCommand('ifdown $name 2>/dev/null || /etc/init.d/openvpn stop $name 2>/dev/null || true');
  }

  Future<void> vpnEnable(String name, String type) async {
    if (type == 'OpenVPN') {
      await runCommand('uci set openvpn.$name.enabled=1; uci commit openvpn');
      await runCommand('/etc/init.d/openvpn reload');
    } else {
      await runCommand('uci set network.$name.disabled=0; uci commit network');
      await runCommand('ifup $name');
    }
  }

  Future<void> vpnDisable(String name, String type) async {
    if (type == 'OpenVPN') {
      await runCommand('uci set openvpn.$name.enabled=0; uci commit openvpn');
      await runCommand('/etc/init.d/openvpn reload');
    } else {
      await runCommand('uci set network.$name.disabled=1; uci commit network');
      await runCommand('ifdown $name');
    }
  }

  Future<void> addWireGuard({
    required String name,
    required String privateKey,
    required String addresses,
    required String publicKey,
    required String endpoint,
    required String allowedIps,
    required String dns,
    bool amnezia = false,
    int listenPort = 0,
  }) async {
    final proto = amnezia ? 'amneziawg' : 'wireguard';
    final pkg = amnezia ? 'amneziawg-tools' : 'wireguard-tools';
    final cfg = '''
uci set network.$name=interface
uci set network.$name.proto='$proto'
uci set network.$name.private_key='$privateKey'
uci set network.$name.listen_port='$listenPort'
uci add_list network.$name.addresses='$addresses'

uci set network.${name}_peer=wireguard_$name
uci set network.${name}_peer.public_key='$publicKey'
uci set network.${name}_peer.persistent_keepalive='25'
uci set network.${name}_peer.endpoint_host='${endpoint.split(':').first}'
uci set network.${name}_peer.endpoint_port='${endpoint.contains(':') ? endpoint.split(':').last : '51820'}'

for ip in ${allowedIps.replaceAll(',', ' ')}; do
  uci add_list network.${name}_peer.allowed_ips="\$ip"
done

# Firewall zone
uci set firewall.${name}_zone=zone
uci set firewall.${name}_zone.name='vpn'
uci set firewall.${name}_zone.input='ACCEPT'
uci set firewall.${name}_zone.output='ACCEPT'
uci set firewall.${name}_zone.forward='REJECT'
uci set firewall.${name}_zone.masq='1'
uci add_list firewall.${name}_zone.network='$name'

uci commit network
uci commit firewall
/etc/init.d/network reload
/etc/init.d/firewall reload
'''.trim();
    await runCommand('opkg list-installed | grep -q $pkg || opkg install $pkg');
    await runCommand(cfg);
  }

  Future<void> removeVpn(String name, String type) async {
    if (type == 'OpenVPN') {
      await runCommand('uci delete openvpn.$name; uci commit openvpn; /etc/init.d/openvpn reload');
    } else {
      await runCommand('ifdown $name 2>/dev/null || true');
      await runCommand('uci delete network.$name; uci delete network.${name}_peer; uci commit network; /etc/init.d/network reload');
    }
  }

  Future<List<String>> fetchLogs({int lines = 100}) async {
    final raw = await runCommand('logread -l $lines 2>/dev/null || dmesg | tail -n $lines');
    return LineSplitter.split(raw).toList();
  }

  Future<String> pingHost(String host, {int count = 4}) async {
    return runCommand('ping -c $count -W 2 $host 2>&1');
  }

  Future<String> fetchPublicIp() async {
    return runCommand('(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null) || (uclient-fetch -qO- --timeout=5 https://api.ipify.org 2>/dev/null) || echo "недоступно"');
  }

  Future<void> restartService(String name) async {
    await runCommand('/etc/init.d/$name restart');
  }

  Future<Map<String, bool>> checkDependencies() async {
    final commands = {
      'ubus': 'type ubus',
      'jsonfilter': 'type jsonfilter',
      'iwinfo': 'type iwinfo',
      'iw': 'type iw',
      'nft': 'type nft',
      'conntrack': 'type conntrack',
      'vnstat': 'type vnstat',
      'tcpdump': 'type tcpdump',
      'wget/uclient': 'test -x /usr/bin/wget || test -x /usr/bin/uclient-fetch',
      'curl': 'type curl',
      'auc': 'test -x /usr/sbin/auc || test -x /sbin/auc',
      'wg': 'type wg',
      'openvpn': 'test -x /usr/sbin/openvpn || test -x /sbin/openvpn',
      'pptp': 'test -x /usr/sbin/pptp || test -x /usr/sbin/pppd',
      'sstpc': 'test -x /usr/sbin/sstpc',
      'strongswan': 'test -x /usr/sbin/ipsec || test -x /usr/sbin/charon',
      'xl2tpd': 'test -x /usr/sbin/xl2tpd',
      'wol': 'test -x /usr/bin/wol || test -x /usr/sbin/etherwake',
      'nmap': 'type nmap',
    };
    final result = <String, bool>{};
    for (final entry in commands.entries) {
      try {
        final out = await runCommand('(${entry.value}) 2>/dev/null >/dev/null && echo OK || echo MISSING');
        result[entry.key] = out.trim() == 'OK';
      } catch (_) {
        try {
          final cmd = entry.value.replaceAll('type ', 'command -v ');
          final out = await runCommand('($cmd) 2>/dev/null >/dev/null && echo OK || echo MISSING');
          result[entry.key] = out.trim() == 'OK';
        } catch (_) { result[entry.key] = false; }
      }
    }
    return result;
  }

  Future<String> detectPackageManager() async {
    try {
      final res = await runCommand('which apk 2>/dev/null && echo APK || (which opkg 2>/dev/null && echo OPKG || echo NONE)');
      return res.trim();
    } catch (_) {
      return 'OPKG';
    }
  }

  Future<void> installPackages(List<String> packages) async {
    if (packages.isEmpty) return;
    final pkg = await detectPackageManager();

    // Метод 1: штатный менеджер пакетов
    try {
      if (pkg == 'APK') {
        await runCommand('apk update && apk add ${packages.join(' ')}');
      } else {
        await runCommand('opkg update && opkg install ${packages.join(' ')}');
      }
      return;
    } catch (e) {
      // Метод 2 (fallback): opkg с force-depends
      if (pkg != 'APK') {
        try {
          await runCommand('opkg update && opkg install --force-depends ${packages.join(' ')}');
          return;
        } catch (_) {}
      }
      // Метод 3 (fallback): установка по одному
      for (final p in packages) {
        try {
          if (pkg == 'APK') {
            await runCommand('apk add $p');
          } else {
            await runCommand('opkg install --force-depends $p');
          }
        } catch (_) {}
      }
    }
  }

  static const Map<String, List<String>> packageAlternatives = {
    'auc': ['attendedsysupgrade-common'],
    'wol': ['wol', 'etherwake'],
    'pptp': ['pptp', 'ppp-mod-pptp'],
    'sstpc': ['sstp-client'],
    'strongswan': ['strongswan-default', 'strongswan-minimal'],
    'xl2tpd': ['xl2tpd'],
    'iperf3': ['iperf3', 'iperf3-ssl'],
    'macchanger': ['macchanger'],
    'nlbwmon': ['nlbwmon'],
    'pixiewps': ['pixiewps'],
  };

  Future<bool> isPackageInRepo(String name) async {
    try {
      final r = await runCommand('opkg list 2>/dev/null | grep -m1 "^$name " || echo "NO"');
      return !r.contains('NO') && r.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<String?> findAlternativePackage(String target) async {
    final alts = packageAlternatives[target] ?? [target];
    for (final a in alts) {
      if (await isPackageInRepo(a)) return a;
    }
    return null;
  }

  static const Map<String, String> packageForDependency = {
    'jsonfilter': 'jsonfilter', 'iwinfo': 'iwinfo', 'iw': 'iw',
    'nft': 'nftables', 'conntrack': 'conntrack', 'vnstat': 'vnstat2',
    'tcpdump': 'tcpdump', 'curl': 'curl',
    'auc': 'attendedsysupgrade-common', 'wg': 'wireguard-tools',
    'openvpn': 'openvpn-openssl', 'pptp': 'pptp',
    'sstpc': 'sstp-client', 'strongswan': 'strongswan-default',
    'xl2tpd': 'xl2tpd', 'wol': 'wol', 'nmap': 'nmap',
    'wget/uclient': 'wget',
    'iperf3': 'iperf3', 'macchanger': 'macchanger',
    'nlbwmon': 'nlbwmon', 'pixiewps': 'pixiewps',
  };

  int _parseBytes(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.toInt();
    return int.tryParse(value.toString()) ?? 0;
  }

  Future<List<ClientInfo>> fetchClientsWithTraffic() async {
    final List<ClientInfo> result = [];
    final Map<String, int> macToMonthRx = {};
    final Map<String, int> macToMonthTx = {};
    final Map<String, int> macToWifiRx = {};
    final Map<String, int> macToWifiTx = {};
    final Map<String, int> macToSignal = {};
    final Map<String, String> macToBand = {};
    final Map<String, String> macToIp = {};
    final Map<String, String> macToHostname = {};
    final Map<String, String> macToIface = {};
    final Map<String, String> macToBitrateRx = {};
    final Map<String, String> macToBitrateTx = {};
    final Set<String> activeMacs = {};
    final Set<String> wifiMacs = {};
    final Set<String> wiredMacs = {};
    final String routerIp = '192.168.1.1';

    // 1. Одним SSH-запросом получаем все данные
    final raw = await runCommand("""
route_iface=\$(ip route | grep '^default' | head -n1 | awk '{print \$5}');
echo '===WAN_RX==='; cat /sys/class/net/\$route_iface/statistics/rx_bytes 2>/dev/null || echo 0;
echo '===WAN_TX==='; cat /sys/class/net/\$route_iface/statistics/tx_bytes 2>/dev/null || echo 0;
echo '===WIFI==='; for iface in \$(iw dev 2>/dev/null | grep Interface | awk '{print \$2}'); do
  freq=\$(iw dev \$iface info 2>/dev/null | grep -oE '[0-9]+ MHz' | head -n1 | awk '{print \$1}');
  [ -z "\$freq" ] && freq=0;
  iw dev \$iface station dump | awk -v ifc="\$iface" -v f="\$freq" 'BEGIN{mac=""}
    /^Station/ { if(mac!="") { if(rxb=="") rxb="-"; if(txb=="") txb="-"; print mac, rx, tx, ifc, f, rxb, txb }
      mac=\$2; rx=0; tx=0; rxb=""; txb="" }
    /rx bytes:/ { rx=\$3 } /tx bytes:/ { tx=\$3 }
    /rx bitrate:/ { rxb=\$3" "\$4 } /tx bitrate:/ { txb=\$3" "\$4 }
    /signal:/ { sig=\$2 } /signal avg:/ { sig=\$2 }
    END { if(mac!="") { if(rxb=="") rxb="-"; if(txb=="") txb="-"; print mac, rx, tx, ifc, f, rxb, txb } }';
done;
echo '===LEASES==='; cat /tmp/dhcp.leases 2>/dev/null;
echo '===ARP==='; cat /proc/net/arp 2>/dev/null;
echo '===FDB==='; bridge fdb show br-lan 2>/dev/null | grep dev | grep -v 'self' 2>/dev/null;
echo '===DSA==='; for lan in \$(ls /sys/class/net/ 2>/dev/null | grep -E '^lan[0-9]+\$'); do
  carrier=\$(cat /sys/class/net/\$lan/carrier 2>/dev/null || echo 0);
  rx=\$(cat /sys/class/net/\$lan/statistics/rx_bytes 2>/dev/null || echo 0);
  tx=\$(cat /sys/class/net/\$lan/statistics/tx_bytes 2>/dev/null || echo 0);
  echo "\$lan \$carrier \$rx \$tx";
done;
echo '===NLBW==='; if command -v nlbw >/dev/null; then nlbw -c csv -g mac,date 2>/dev/null | grep -E "(mac|\$(date +%F))"; fi;
echo '===DONE==='
""").timeout(const Duration(seconds: 15));

    // 2. Парсим секции
    String _extractSection(String raw, String marker) {
      final start = '===$marker===';
      final startIdx = raw.indexOf(start);
      if (startIdx < 0) return '';
      int contentStart = startIdx + start.length;
      if (contentStart < raw.length && raw[contentStart] == '\n') contentStart++;
      final nextMarker = raw.indexOf('\n===', contentStart);
      if (nextMarker < 0) return raw.substring(contentStart).trim();
      return raw.substring(contentStart, nextMarker).trim();
    }

    final wifiSection = _extractSection(raw, 'WIFI');
    final leasesSection = _extractSection(raw, 'LEASES');
    final arpSection = _extractSection(raw, 'ARP');
    final fdbSection = _extractSection(raw, 'FDB');
    final nlbwSection = _extractSection(raw, 'NLBW');

    // 3. DHCP Leases
    for (final line in LineSplitter.split(leasesSection)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        final mac = parts[1].toLowerCase();
        activeMacs.add(mac);
        macToIp[mac] = parts[2];
        macToHostname[mac] = parts[3] != '*' ? parts[3] : 'Unknown';
      }
    }

    // 4. ARP
    for (final line in LineSplitter.split(arpSection)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 4 && parts[3] != '00:00:00:00:00:00') {
        final mac = parts[3].toLowerCase();
        if (!activeMacs.contains(mac)) {
          activeMacs.add(mac);
          macToHostname[mac] = 'Unknown';
        }
        if (parts[2] != '0x0') {
          macToIp[mac] = parts[0];
        }
        macToIface[mac] = parts.last;
      }
    }

    // 5. WiFi station dump
    for (final line in LineSplitter.split(wifiSection)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        final mac = parts[0].toLowerCase();
        final rx = int.tryParse(parts[1]) ?? 0;
        final tx = int.tryParse(parts[2]) ?? 0;
        final iface = parts[3];
        final freq = int.tryParse(parts.length > 4 ? parts[4] : '0') ?? 0;
        final rxBitrate = parts.length >= 7 ? '${parts[5]} ${parts[6]}' : null;
        final txBitrate = parts.length >= 9 ? '${parts[7]} ${parts[8]}' : null;

        String band = 'Wi-Fi ($iface)';
        if (freq >= 2400 && freq <= 2500) band = 'Wi-Fi 2.4GHz';
        else if (freq >= 5000 && freq <= 5900) band = 'Wi-Fi 5GHz';
        else if (freq >= 5900 && freq <= 7200) band = 'Wi-Fi 6GHz';

        macToWifiRx[mac] = rx;
        macToWifiTx[mac] = tx;
        macToBand[mac] = band;
        macToIface[mac] = iface;
        if (rxBitrate != null) macToBitrateRx[mac] = rxBitrate;
        if (txBitrate != null) macToBitrateTx[mac] = txBitrate;
        wifiMacs.add(mac);
        activeMacs.add(mac);
      }
    }

    // 6. Bridge FDB — проводные клиенты
    for (final line in LineSplitter.split(fdbSection)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 3 && parts[1] == 'dev') {
        final mac = parts[0].toLowerCase();
        final dev = parts[2];
        final isWifiDev = dev.startsWith('phy') || dev.startsWith('wlan') ||
            dev.startsWith('ath') || dev.startsWith('ra') || dev.startsWith('rai') || dev.contains('ap');
        if (!isWifiDev && !parts.contains('permanent') && !parts.contains('self')) {
          wiredMacs.add(mac);
          macToIface[mac] = dev;
        }
      }
    }

    // 7. NLBW — месячный трафик
    int rxIdx = -1, txIdx = -1, macIdx = 0;
    for (final (idx, line) in LineSplitter.split(nlbwSection).indexed) {
      final parts = line.trim().split(',');
      if (idx == 0 && (line.contains('rx_bytes') || line.contains('rx'))) {
        for (int i = 0; i < parts.length; i++) {
          final p = parts[i].replaceAll('"', '').toLowerCase();
          if (p.contains('rx')) rxIdx = i;
          if (p.contains('tx')) txIdx = i;
          if (p.contains('mac')) macIdx = i;
        }
        continue;
      }
      if (rxIdx == -1) {
        if (parts.length >= 6) { macIdx = 0; rxIdx = 3; txIdx = 4; }
        else if (parts.length >= 4) { macIdx = 0; rxIdx = 2; txIdx = 3; }
      }
      if (parts.length > [rxIdx, txIdx, macIdx].reduce((a, b) => a > b ? a : b) && rxIdx != -1) {
        final mac = parts[macIdx].replaceAll('"', '').toLowerCase();
        macToMonthRx[mac] = int.tryParse(parts[rxIdx].replaceAll('"', '')) ?? 0;
        macToMonthTx[mac] = int.tryParse(parts[txIdx].replaceAll('"', '')) ?? 0;
      }
    }

    // 8. Собираем результат
    for (final mac in activeMacs) {
      final ip = macToIp[mac];
      if (ip == routerIp || ip == '127.0.0.1') continue;
      final isWifi = wifiMacs.contains(mac);
      final isWired = wiredMacs.contains(mac);
      String connectionType;
      String? accessPoint;
      if (isWifi) {
        connectionType = macToBand[mac] ?? 'Wi-Fi';
        accessPoint = macToIface[mac];
      } else if (isWired) {
        connectionType = 'LAN';
        accessPoint = macToIface[mac];
      } else {
        connectionType = 'LAN';
      }

      result.add(ClientInfo(
        hostname: macToHostname[mac] ?? 'Unknown',
        mac: mac,
        ip: ip,
        active: true,
        rxBytes: macToWifiRx[mac] ?? 0,
        txBytes: macToWifiTx[mac] ?? 0,
        monthRxBytes: macToMonthRx[mac] ?? 0,
        monthTxBytes: macToMonthTx[mac] ?? 0,
        connectionType: connectionType,
        accessPoint: accessPoint,
        rxBitrate: macToBitrateRx[mac],
        txBitrate: macToBitrateTx[mac],
      ));
    }

    return result;
  }

  Future<List<String>> fetchBlockedMacs() async {
    try {
      final raw = await runCommand('nft list set inet fw4 blocklist 2>/dev/null || echo ""');
      final macs = <String>[];
      final re = RegExp(r'([0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2})');
      for (final m in re.allMatches(raw.toLowerCase())) {
        macs.add(m.group(1)!);
      }
      return macs;
    } catch (_) {
      return [];
    }
  }

  Future<void> blockClient(String mac) async {
    final cleanMac = mac.toLowerCase();
    await runCommand('''
      nft add set inet fw4 blocklist { type ether_addr\\; flags timeout\\; } 2>/dev/null || true
      nft add rule inet fw4 forward ether saddr @blocklist drop 2>/dev/null || true
      nft add element inet fw4 blocklist { $cleanMac } 2>/dev/null || true
    ''');
  }

  Future<Map<String, String>> remoteAccessStatus() async {
    final result = <String, String>{};
    // WAN IP
    try { result['wan_ip'] = (await runCommand('wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || uclient-fetch -qO- --timeout=3 https://api.ipify.org 2>/dev/null || echo ""')).trim(); } catch (_) { result['wan_ip'] = '?'; }
    // Проверяем существующие redirect правила
    try {
      final raw = await runCommand('uci show firewall 2>/dev/null | grep -E "=redirect" | grep -E "dest_port.*22" || echo ""');
      if (raw.isNotEmpty) {
        final m = RegExp(r'firewall\.([^=]+)=redirect').firstMatch(raw);
        if (m != null) {
          result['rule_section'] = m.group(1)!;
          result['src_port'] = (await runCommand('uci get firewall.${m.group(1)}.src_dport 2>/dev/null || echo ""')).trim();
          result['enabled'] = (await runCommand('uci get firewall.${m.group(1)}.enabled 2>/dev/null || echo "1"')).trim();
        }
      }
    } catch (_) {}
    return result;
  }

  Future<void> enableRemoteAccess({int port = 22022}) async {
    await runCommand("""
uci add firewall redirect 2>/dev/null || true
uci set firewall.@redirect[-1].name='OpenWrtManagerRemote'
uci set firewall.@redirect[-1].src='wan'
uci set firewall.@redirect[-1].proto='tcp'
uci set firewall.@redirect[-1].src_dport='$port'
uci set firewall.@redirect[-1].dest_port='22'
uci set firewall.@redirect[-1].target='DNAT'
uci set firewall.@redirect[-1].enabled='1'
uci commit firewall
/etc/init.d/firewall reload
""");
  }

  Future<void> disableRemoteAccess() async {
    await runCommand("""
for section in \$(uci show firewall 2>/dev/null | grep '=redirect' | grep 'OpenWrtManagerRemote\|dest_port.*22' | cut -d'.' -f2 | cut -d'=' -f1); do
  uci delete firewall.\$section 2>/dev/null
done
uci commit firewall
/etc/init.d/firewall reload
""");
  }

  Future<void> unblockClient(String mac) async {
    final cleanMac = mac.toLowerCase();
    await runCommand('nft delete element inet fw4 blocklist { $cleanMac } 2>/dev/null || true');
  }
}