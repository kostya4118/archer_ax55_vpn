# VLESS VPN через NanoPi R2S для TP-Link Archer AX55

Гайд по настройке VPN-шлюза на NanoPi R2S с выборочной маршрутизацией трафика через VLESS. Archer AX55 при этом остаётся в штатном режиме и не модифицируется.

## Схема сети

```
Интернет → Провайдер → NanoPi R2S (WAN) → (LAN) Archer AX55 → Устройства
```

NanoPi R2S стоит между провайдером и роутером. Он решает, какой трафик направить через VLESS, а какой — напрямую. Archer AX55 работает только как Wi-Fi точка доступа.

## Что понадобится

- NanoPi R2S (RK3328, 1 ГБ DDR4) — [Ozon](https://www.ozon.ru/product/2045771530/)
- MicroSD карта 8–16 ГБ (Class 10)
- Два патч-корда (провайдер → NanoPi, NanoPi → роутер)
- Компьютер для записи образа
- VLESS-ссылка вида `vless://...` (от твоего VPN-сервера)

## Шаг 1: Запись OpenWrt на MicroSD

### Скачать образ

Перейди на страницу OpenWrt для NanoPi R2S:
```
https://openwrt.org/toh/friendlyarm/nanopi_r2s
```

Скачай последний стабильный образ:
```
openwrt-<версия>-rockchip-armv8-friendlyarm_nanopi-r2s-ext4-sysupgrade.img.gz
```

### Записать на MicroSD

**На Linux/Mac:**
```bash
# Распакуй образ
gunzip openwrt-*-nanopi-r2s-ext4-sysupgrade.img.gz

# Запиши на карту (замени /dev/sdX на свой диск — проверь через lsblk!)
dd if=openwrt-*-nanopi-r2s-ext4-sysupgrade.img of=/dev/sdX bs=4M status=progress
sync
```

**На Windows:**
- Используй [balenaEtcher](https://etcher.balena.io/) — выбери .img.gz файл и MicroSD карту, нажми Flash.

## Шаг 2: Первый запуск

1. Вставь MicroSD в NanoPi R2S
2. Подключи **LAN-порт NanoPi** к компьютеру патч-кордом
3. Включи питание (USB-C, 5V/3A)
4. Подожди 1–2 минуты

Открой браузер: `http://192.168.1.1` — должен появиться интерфейс OpenWrt LuCI.

Логин: `root`, пароль: пустой (задай при первом входе).

## Шаг 3: Подключение к провайдеру

### Физическое подключение

```
Кабель провайдера → WAN-порт NanoPi R2S
LAN-порт NanoPi R2S → WAN-порт Archer AX55
```

### Настройка WAN в OpenWrt

В LuCI: **Network → Interfaces → WAN → Edit**

- Если провайдер выдаёт IP автоматически: протокол `DHCP client`
- Если PPPoE: протокол `PPPoE`, введи логин и пароль от провайдера
- Сохрани и применй

### Настройка Archer AX55

В веб-интерфейсе AX55 (`192.168.0.1` или стандартный адрес):

- Зайди в настройки WAN
- Поменяй тип подключения на **Dynamic IP (DHCP)**
- Сохрани

Теперь AX55 получает адрес от NanoPi, а не от провайдера напрямую.

## Шаг 4: Установка sing-box

Подключись к NanoPi по SSH:
```bash
ssh root@192.168.1.1
```

Установи пакеты:
```bash
opkg update
opkg install sing-box
opkg install kmod-tun  # TUN-интерфейс для VPN
```

## Шаг 5: Конфигурация VLESS

Создай файл конфигурации:
```bash
vi /etc/sing-box/config.json
```

Вставь следующий шаблон (замени значения в блоке `outbounds` на данные своего сервера):

```json
{
  "log": {
    "level": "warn",
    "output": "/var/log/sing-box.log"
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-proxy",
        "address": "https://8.8.8.8/dns-query",
        "detour": "proxy"
      },
      {
        "tag": "dns-direct",
        "address": "https://77.88.8.8/dns-query",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-ru",
        "server": "dns-direct"
      }
    ],
    "final": "dns-proxy"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "auto_route": true,
      "strict_route": true,
      "sniff": true
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "ВАШ_СЕРВЕР",
      "server_port": 443,
      "uuid": "ВАШ_UUID",
      "tls": {
        "enabled": true,
        "server_name": "ВАШ_SNI",
        "reality": {
          "enabled": true,
          "public_key": "ВАШ_PUBLIC_KEY",
          "short_id": "ВАШ_SHORT_ID"
        }
      },
      "packet_encoding": "xudp"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "bittorrent",
        "outbound": "direct"
      },
      {
        "rule_set": "geosite-ru",
        "outbound": "direct"
      },
      {
        "rule_set": "geoip-ru",
        "outbound": "direct"
      },
      {
        "ip_cidr": ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"],
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geosite-ru",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-ru.srs",
        "download_detour": "direct",
        "update_interval": "7d"
      },
      {
        "tag": "geoip-ru",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "download_detour": "direct",
        "update_interval": "7d"
      }
    ],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
```

### Как заполнить данные сервера

Если у тебя есть VLESS-ссылка вида:
```
vless://UUID@СЕРВЕР:443?security=reality&sni=SNI&pbk=PUBLIC_KEY&sid=SHORT_ID#Название
```

Раскладывай по полям:
- `server` → `СЕРВЕР`
- `uuid` → `UUID`
- `server_name` → `SNI`
- `public_key` → `PUBLIC_KEY`
- `short_id` → `SHORT_ID`

## Шаг 6: Запуск и автозапуск

```bash
# Проверить конфиг на ошибки
sing-box check -c /etc/sing-box/config.json

# Запустить
/etc/init.d/sing-box start

# Включить автозапуск при загрузке
/etc/init.d/sing-box enable
```

## Шаг 7: Проверка

С любого устройства в сети:

```bash
# Проверить внешний IP (должен быть IP VPN-сервера для зарубежных сайтов)
curl https://ifconfig.me

# Проверить что российские сайты идут напрямую
curl -v https://ya.ru 2>&1 | grep "Connected to"
```

Онлайн-проверка утечек DNS: [dnsleaktest.com](https://dnsleaktest.com)

## Логика маршрутизации

| Трафик | Путь |
|--------|------|
| BitTorrent | Напрямую |
| Российские домены (geosite-ru) | Напрямую |
| Российские IP (geoip-ru) | Напрямую |
| Локальная сеть (192.168.x.x) | Напрямую |
| Всё остальное | Через VLESS |

## Устранение проблем

**Нет интернета после подключения NanoPi:**
```bash
# Проверить WAN
ping -c 3 8.8.8.8 -I eth0

# Проверить DNS
nslookup google.com
```

**sing-box не запускается:**
```bash
# Смотреть логи
logread | grep sing-box
cat /var/log/sing-box.log
```

**Все сайты идут через VPN (российские тоже):**
- Проверь что rule_set скачались: в логах должно быть `updated rule-set`
- Если нет — проверь доступ к github.com с NanoPi

## Дополнительно: выборочная маршрутизация по устройствам

Если нужно пускать через VPN только конкретные устройства, а не все:

1. В LuCI привяжи MAC-адрес устройства к статическому IP: **Network → DHCP → Static Leases**
2. В конфиге sing-box добавь в `rules` перед финальным правилом:

```json
{
  "source_ip_cidr": ["192.168.1.100/32"],
  "outbound": "direct"
}
```

Или наоборот — пускать через VPN только одно устройство:

```json
{
  "source_ip_cidr": ["192.168.1.101/32"],
  "outbound": "proxy"
}
```

И поменяй `"final": "proxy"` на `"final": "direct"`.

## Дополнительно: торрент-трафик напрямую (без VPN)

Если VLESS-сервер блокирует BitTorrent или есть лимит трафика — торренты можно пустить напрямую, минуя VPN.

В конфиге правило `bittorrent` должно стоять **первым** в списке `rules`:

```json
"route": {
  "rules": [
    {
      "protocol": "bittorrent",
      "outbound": "direct"
    },
    {
      "rule_set": "geosite-ru",
      "outbound": "direct"
    },
    ...
  ]
}
```

sing-box определяет BitTorrent автоматически благодаря `"sniff": true` в inbound — дополнительных настроек не нужно. Правило срабатывает на DHT, магнет-ссылки и обычные .torrent соединения.

## Дополнительно: доступ из внешней сети (с телефона на улице)

Если хочешь подключаться к домашней сети с телефона и использовать VLESS через NanoPi:

```
Телефон (в кафе/роуминге)
    ↓ WireGuard
NanoPi R2S дома
    ↓ VLESS
VPN-сервер за рубежом
    ↓
YouTube, Instagram, etc.
```

### Требования

- Белый IP от провайдера (проверить на 2ip.ru)
- Если IP меняется — настроить DDNS (No-IP, DynDNS)

### Установка WireGuard на NanoPi

```bash
opkg install wireguard-tools kmod-wireguard luci-app-wireguard
```

Настроить через LuCI: **Network → WireGuard** — сгенерировать ключи, добавить peer (телефон).

На телефоне установить приложение **WireGuard** (iOS/Android) и импортировать конфиг.

### Проброс порта на Archer AX55

В настройках AX55: **Advanced → NAT Forwarding → Port Forwarding**
- Внешний порт: `51820` (UDP)
- Внутренний IP: `192.168.1.1` (NanoPi)
- Внутренний порт: `51820`
