import 'package:flutter/material.dart';
import '../models/router_connection.dart';
import '../services/openwrt_service.dart';
import '../services/storage_service.dart';
import 'about_screen.dart';
import 'dashboard_screen.dart';
import 'monitor_screen.dart';
import 'network_screen.dart';
import 'vpn_screen.dart';
import 'clients_screen.dart';
import 'packages_screen.dart';
import 'system_screen.dart';
import 'wifi_screen.dart';
import 'login_screen.dart';
import 'terminal_screen.dart';
import 'mac_changer_screen.dart';
import 'wps_audit_screen.dart';

class HomeScreen extends StatefulWidget {
  final RouterConnection config;

  const HomeScreen({super.key, required this.config});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late final OpenWrtService service;
  late final PageController pageController;
  int index = 0;
  bool _checkedDeps = false;

  final destinations = const [
    NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'Обзор'),
    NavigationDestination(icon: Icon(Icons.network_check_outlined), selectedIcon: Icon(Icons.network_check), label: 'Сеть'),
    NavigationDestination(icon: Icon(Icons.wifi_outlined), selectedIcon: Icon(Icons.wifi), label: 'Wi-Fi'),
    NavigationDestination(icon: Icon(Icons.vpn_key_outlined), selectedIcon: Icon(Icons.vpn_key), label: 'VPN'),
    NavigationDestination(icon: Icon(Icons.devices_outlined), selectedIcon: Icon(Icons.devices), label: 'Клиенты'),
    NavigationDestination(icon: Icon(Icons.inventory_2_outlined), selectedIcon: Icon(Icons.inventory_2), label: 'Пакеты'),
    NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Система'),
  ];

  @override
  void initState() {
    super.initState();
    service = OpenWrtService(widget.config);
    pageController = PageController(initialPage: 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _firstStartCheck());
  }

  Future<void> _firstStartCheck() async {
    if (_checkedDeps) return;
    _checkedDeps = true;

    final alreadyChecked = await StorageService.wasDepsChecked(widget.config.host);
    if (alreadyChecked) return;

    try {
      await service.connect();
      final pkg = await service.detectPackageManager();
      final allDeps = await service.checkDependencies();
      await service.disconnect();
      if (!mounted) return;

      final missing = allDeps.entries.where((e) => !e.value && e.key != 'ubus').toList();
      if (missing.isEmpty) {
        await StorageService.markDepsChecked(widget.config.host);
        return;
      }

      _showDepsDialog(pkg, allDeps);
    } catch (_) {}
  }

  void _showDepsDialog(String pkgManager, Map<String, bool> allDeps) {
    final entries = allDeps.entries.where((e) => e.key != 'ubus').toList();
    final missingEntries = entries.where((e) => !e.value).toList();
    final status = <String, String>{};
    var installing = false;
    String? resultMsg;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            title: Row(children: [
              const Icon(Icons.checklist_rtl),
              const SizedBox(width: 8),
              Expanded(child: Text('Зависимости — $pkgManager', style: const TextStyle(fontSize: 17))),
              Text('${entries.where((e) => e.value).length}/${entries.length}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ]),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ...entries.map((e) {
                  final ok = status[e.key] == 'done' || (status[e.key] != 'error' && e.value);
                  final failed = status[e.key] == 'error';
                  final loading = status[e.key] == 'downloading';
                  final pn = OpenWrtService.packageForDependency[e.key];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(children: [
                      if (loading)
                        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        Icon(ok && !failed ? Icons.check_circle : Icons.cancel, size: 22, color: ok && !failed ? Colors.green : Colors.red),
                      const SizedBox(width: 10),
                      Expanded(child: Text(e.key, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
                      if (pn != null) Text('→ $pn', style: Theme.of(ctx).textTheme.bodySmall),
                    ]),
                  );
                }),
                if (installing) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
                if (resultMsg != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(resultMsg!, style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600))),
              ]),
            ),
            actions: [
              TextButton(onPressed: installing ? null : () => Navigator.pop(ctx), child: const Text('Закрыть')),
              if (missingEntries.isNotEmpty)
                FilledButton.icon(
                  onPressed: installing ? null : () async {
                    final toInstall = missingEntries
                        .where((e) => e.key != 'ubus' && e.key != 'wget/uclient')
                        .map((e) => OpenWrtService.packageForDependency[e.key])
                        .whereType<String>()
                        .toList();
                    if (toInstall.isEmpty) return;
                    setSt(() => installing = true);
                    try {
                      await service.connect();
                      for (final pkg in toInstall) {
                        setSt(() { status[pkg] = 'downloading'; resultMsg = 'Загрузка $pkg...'; });
                        try {
                          await service.installPackages([pkg]);
                          setSt(() { status[pkg] = 'done'; resultMsg = 'Готово $pkg'; });
                        } catch (_) {
                          setSt(() { status[pkg] = 'error'; resultMsg = 'Ошибка $pkg'; });
                        }
                        await Future.delayed(const Duration(milliseconds: 300));
                      }
                      await service.disconnect();
                      setSt(() { installing = false; resultMsg = 'Готово'; });
                      await StorageService.markDepsChecked(widget.config.host);
                      await Future.delayed(const Duration(seconds: 2));
                      if (!mounted) return;
                      Navigator.pop(ctx);
                      _offerRebootAfterInstall();
                    } catch (e) {
                      setSt(() { installing = false; resultMsg = 'Ошибка: $e'; });
                    }
                  },
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Установить'),
                ),
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  void _offerRebootAfterInstall() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Перезагрузить роутер?'),
        content: const Text('Некоторые пакеты требуют перезагрузки.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Позже')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                await service.connect();
                await service.reboot();
                await service.disconnect();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Роутер перезагружается...')));
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
              }
            },
            child: const Text('Перезагрузить'),
          ),
        ],
      ),
    );
  }

  void _onPageChanged(int i) => setState(() => index = i);

  void _onTabSelected(int i) {
    pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _switchRouter() async {
    final routers = await StorageService.loadRouters();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Выбор роутера', style: Theme.of(ctx).textTheme.titleLarge),
            ),
            ...routers.map((r) => ListTile(
                  leading: const Icon(Icons.router),
                  title: Text(r.name),
                  subtitle: Text('${r.username}@${r.host}:${r.port}'),
                  trailing: r.host == widget.config.host ? const Icon(Icons.check, color: Colors.green) : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => HomeScreen(config: r)),
                    );
                  },
                )),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Выйти на экран входа'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                width: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [theme.colorScheme.primary, theme.colorScheme.tertiary]),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.asset('assets/icon/router_icon.png', width: 64, height: 64),
                    const SizedBox(height: 16),
                    Text(widget.config.name, style: theme.textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                    Text('${widget.config.username}@${widget.config.host}', style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70)),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.multiline_chart),
                title: const Text('Мониторинг соединений'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => MonitorScreen(service: service)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Сменить роутер'),
                onTap: () {
                  Navigator.pop(context);
                  _switchRouter();
                },
              ),
              ListTile(
                leading: const Icon(Icons.terminal),
                title: const Text('Терминал (Beta)'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => TerminalScreen(service: service)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('MAC Changer'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MacChangerScreen(service: service)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.wifi_lock),
                title: const Text('WPS Audit'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => WpsAuditScreen(service: service)));
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('О приложении'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutScreen()));
                },
              ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('OPENWRT - Global v3.7.0\nРыбинскLAB', style: TextStyle(color: Colors.grey), textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
      ),
      body: PageView(
        controller: pageController,
        onPageChanged: _onPageChanged,
        physics: const BouncingScrollPhysics(),
        children: [
          DashboardScreen(service: service),
          NetworkScreen(service: service),
          WifiScreen(service: service),
          VpnScreen(service: service),
          ClientsScreen(service: service),
          PackagesScreen(service: service),
          SystemScreen(service: service),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: _onTabSelected,
        animationDuration: const Duration(milliseconds: 400),
        destinations: destinations,
      ),
    );
  }
}
