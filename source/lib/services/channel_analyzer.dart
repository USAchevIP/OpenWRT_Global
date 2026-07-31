import '../models/channel_scan_result.dart';
import 'openwrt_service.dart';
import 'local_wifi_scanner.dart';

class ChannelAnalyzer {
  final OpenWrtService routerService;

  ChannelAnalyzer(this.routerService);

  Future<ChannelAnalysis> analyze(String deviceName) async {
    final band = await _getBand(deviceName);
    final currentCh = await _getChannel(deviceName);
    final currentHt = await _getHtMode(deviceName);

    // Роутер: детальное сканирование
    List<ChannelScanResult> routerScans = [];
    Map<int, int> routerInterference = {};
    try {
      routerScans = await routerService.scanWifiChannelsDetailed(deviceName);
      routerInterference = await routerService.scanWifiChannels(deviceName);
    } catch (_) {}

    // Телефон: сканирование через WiFi
    List<ChannelScanResult> phoneScans = [];
    try {
      final scanResult = await LocalWifiScanner.scan();
      phoneScans = scanResult.results
          .where((s) => LocalWifiScanner.bandForChannel(s.channel) == band)
          .toList();
    } catch (_) {}

    // Рекомендации
    final recommended = _findBestChannels(
      band: band,
      routerInterference: routerInterference,
      phoneScans: phoneScans,
      preferredWidth: _parseWidthFromHtMode(currentHt),
    );

    return ChannelAnalysis(
      deviceName: deviceName,
      band: band,
      currentChannel: int.tryParse(currentCh) ?? 0,
      currentHtMode: currentHt,
      phoneScans: phoneScans,
      routerScans: routerScans,
      routerInterference: routerInterference,
      recommendedChannels: recommended,
    );
  }

  Future<String> _getBand(String device) async {
    try {
      return (await routerService
              .runCommand('uci get wireless.$device.band 2>/dev/null || echo "2.4g"'))
          .trim();
    } catch (_) {
      return '2.4g';
    }
  }

  Future<String> _getChannel(String device) async {
    try {
      return (await routerService
              .runCommand('uci get wireless.$device.channel 2>/dev/null || echo "auto"'))
          .trim();
    } catch (_) {
      return 'auto';
    }
  }

  Future<String> _getHtMode(String device) async {
    try {
      return (await routerService
              .runCommand('uci get wireless.$device.htmode 2>/dev/null || echo "HT20"'))
          .trim();
    } catch (_) {
      return 'HT20';
    }
  }

  int _parseWidthFromHtMode(String ht) {
    if (ht.contains('160')) return 160;
    if (ht.contains('80')) return 80;
    if (ht.contains('40')) return 40;
    return 20;
  }

  List<int> _findBestChannels({
    required String band,
    required Map<int, int> routerInterference,
    required List<ChannelScanResult> phoneScans,
    int preferredWidth = 80,
  }) {
    final allChannels = _allChannelsForBand(band);
    final combined = <int, int>{};

    for (final ch in allChannels) {
      int count = routerInterference[ch] ?? 0;
      count += phoneScans.where((s) => s.occupiedChannels.contains(ch)).length;
      combined[ch] = count;
    }

    final sorted = combined.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    if (band == '5g') {
      // Для 5 ГГц предпочитаем каналы, которые подходят под ширину
      return sorted.where((e) {
        if (preferredWidth >= 80) return e.key % 8 == 4 || e.key % 8 == 0;
        if (preferredWidth >= 40) return e.key % 4 == 0;
        return true;
      }).map((e) => e.key).toList();
    }

    return sorted.map((e) => e.key).toList();
  }

  List<int> _allChannelsForBand(String band) {
    if (band == '5g') {
      return List.generate(25, (i) => 36 + i * 4).where((c) => c <= 165).toList();
    }
    if (band == '6g') {
      return List.generate(59, (i) => 1 + i * 4).where((c) => c <= 233).toList();
    }
    return List.generate(13, (i) => i + 1);
  }
}