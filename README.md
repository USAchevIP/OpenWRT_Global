# OpenWRT Global Manager

Мобильное приложение для управления роутерами OpenWRT через SSH.

## Возможности

- Системная панель с CPU / RAM мониторингом
- Управление WiFi (частоты, SSID, пароли, ширина канала)
- Поддержка VPN: WireGuard, AmneziaWG, OpenVPN, L2TP, PPTP, SSTP, IPsec
- Мониторинг DHCP-клиентов с определением устройств
- Настройка WAN (ISP-пресеты, Россия)
- Пакетный менеджер opkg / apk
- Резервное копирование и восстановление конфигурации
- Реал-тайм мониторинг соединений (conntrack)

## Структура репозитория

```
source/     # Flutter-приложение (Dart / Android)
releases/   # APK-файлы релизов
```

## Сборка

```bash
cd source
flutter pub get
flutter build apk --release
```

## Лицензия

[MIT](LICENSE) — разрешено использовать, модифицировать и распространять код при условии указания автора **Усачёв Денис (РыбинскLAB.ru)** и ссылки на репозиторий **https://github.com/USAchevIP/OpenWRT_Global**.
