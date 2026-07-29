class NetworkInterface {
  final String name;
  final bool up;
  final String? protocol;
  final String? device;
  final List<String>? ipAddresses;
  final List<String>? ipv6Addresses;
  final String? gateway;
  final String? dns;
  final Map<String, dynamic>? stats;

  NetworkInterface({
    required this.name,
    required this.up,
    this.protocol,
    this.device,
    this.ipAddresses,
    this.ipv6Addresses,
    this.gateway,
    this.dns,
    this.stats,
  });

  factory NetworkInterface.fromUbusJson(String name, Map<String, dynamic> json) {
    final ipv4 = json['ipv4-address'] as List<dynamic>? ?? [];
    final ipv6 = json['ipv6-address'] as List<dynamic>? ?? [];
    final route = json['route'] as List<dynamic>? ?? [];
    final dns = json['dns-server'] as List<dynamic>? ?? [];

    return NetworkInterface(
      name: name,
      up: json['up'] == true,
      protocol: json['proto']?.toString(),
      device: json['device']?.toString(),
      ipAddresses: ipv4.map((e) => '${e['address']}/${e['mask'] ?? ''}').toList(),
      ipv6Addresses: ipv6.map((e) => e['address']?.toString() ?? '').where((s) => s.isNotEmpty).toList(),
      gateway: route.isNotEmpty ? route[0]['nexthop']?.toString() : null,
      dns: dns.isNotEmpty ? dns.join(', ') : null,
      stats: json['statistics'] as Map<String, dynamic>?,
    );
  }

  String get bytesHuman {
    final tx = stats?['tx_bytes'] ?? 0;
    final rx = stats?['rx_bytes'] ?? 0;
    return '↓${formatBytes(rx)} ↑${formatBytes(tx)}';
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
