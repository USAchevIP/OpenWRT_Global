import 'package:intl/intl.dart';

class ClientInfo {
  final String hostname;
  final String mac;
  final String? ip;
  final String? interface;
  final int? leaseExpiry;
  final bool active;
  final int rxBytes;
  final int txBytes;
  final int? signal;
  final String? connectionType;
  final String? accessPoint; // hostapd iface / radio

  ClientInfo({
    required this.hostname,
    required this.mac,
    this.ip,
    this.interface,
    this.leaseExpiry,
    this.active = true,
    this.rxBytes = 0,
    this.txBytes = 0,
    this.signal,
    this.connectionType,
    this.accessPoint,
  });

  int get totalBytes => rxBytes + txBytes;

  String get rxHuman => _formatBytes(rxBytes);
  String get txHuman => _formatBytes(txBytes);
  String get totalHuman => _formatBytes(totalBytes);

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0;
    double d = bytes.toDouble();
    while (d >= 1024 && i < suffixes.length - 1) {
      d /= 1024;
      i++;
    }
    return '${NumberFormat('#0.0').format(d)} ${suffixes[i]}';
  }
}
