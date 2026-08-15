# VLESS VPN + WireGuard сервер на NanoPi R3S

Гайд по настройке NanoPi R3S как VPN-шлюза с:
- **Podkop + VLESS** — выборочная маршрутизация заблокированных сайтов через VPN
- **WireGuard-сервер** — подключение с телефона снаружи через домашнюю сеть

Archer AX55 при этом остаётся в штатном режиме.

## Схема сети

```
Телефон (мобильный интернет)
    ↓ WireGuard
Интернет → Провайдер → NanoPi R3S (WAN) → (LAN) Archer AX55 → Устройства
                              ↓ VLESS (Podkop)
                        Зарубежный сервер
                              ↓
                    Instagram, YouTube, etc.
```

## Что понадобится

- NanoPi R3S (RK3566, 2 ГБ RAM, 32 ГБ eMMC)
- MicroSD карта 4+ ГБ (только для первоначальной прошивки)
- Два патч-корда (провайдер → NanoPi, NanoPi → роутер)
- VLESS-ссылка вида `vless://...`
- Белый IP от провайдера (для WireGuard-сервера)

---

## Часть 1: Установка OpenWrt 24.10

### Шаг 1: Скачать образы

Нужно два образа:

**1. Образ для загрузки с SD-карты** (initramfs — временный, для первого запуска):
```
https://firmware-selector.openwrt.org/?version=24.10.0&target=rockchip%2Farmv8&id=friendlyarm_nanopi-r3s
```
Скачай: `openwrt-24.10.0-rockchip-armv8-friendlyarm_nanopi-r3s-initramfs-kernel.itb`

**2. Образ для прошивки на eMMC** (sysupgrade — постоянный):
```
openwrt-24.10.0-rockchip-armv8-friendlyarm_nanopi-r3s-squashfs-sysupgrade.img.gz
```

### Шаг 2: Записать initramfs на MicroSD

**На Windows:** используй [balenaEtcher](https://etcher.balena.io/)

**На Linux/Mac:**
```bash
gunzip openwrt-*-initramfs-kernel.itb.gz 2>/dev/null || true
dd if=openwrt-*-initramfs-kernel.itb of=/dev/sdX bs=4M status=progress
sync
```
> Замени `/dev/sdX` на свою карту — проверь через `lsblk`!

### Шаг 3: Первый запуск с SD-карты

1. Вставь MicroSD в R3S
2. Подключи **LAN-порт R3S** к компьютеру патч-кордом
3. Включи питание (USB-C, 5V/2A)
4. Подожди 1–2 минуты

OpenWrt загрузится с SD-карты в RAM. Подключись по SSH:
```bash
ssh root@192.168.1.1
# Пароль пустой — нажми Enter
```

### Шаг 4: Прошить OpenWrt на eMMC

Передай sysupgrade-образ на R3S:
```bash
scp openwrt-*-squashfs-sysupgrade.img.gz root@192.168.1.1:/tmp/
```

На R3S прошей eMMC:
```bash
ssh root@192.168.1.1

# Распакуй образ
gunzip /tmp/openwrt-*-squashfs-sysupgrade.img.gz

# Прошей на eMMC
dd if=/tmp/openwrt-*-squashfs-sysupgrade.img of=/dev/mmcblk0 bs=4M conv=fsync status=progress
sync

reboot
```

После перезагрузки **вытащи MicroSD** — R3S загрузится с eMMC.

### Шаг 5: Первичная настройка

Зайди в LuCI: `http://192.168.1.1`

Логин: `root`, пароль: пустой (задай сразу).

---

## Часть 2: Подключение к провайдеру

### Физическое подключение

```
Кабель провайдера → WAN-порт R3S
LAN-порт R3S → WAN-порт Archer AX55
```

### Настройка WAN в OpenWrt

LuCI: **Network → Interfaces → WAN → Edit**

- DHCP: протокол `DHCP client`
- PPPoE: протокол `PPPoE`, логин и пароль от провайдера

### Настройка Archer AX55

В веб-интерфейсе AX55:
- Настройки WAN → тип подключения: **Dynamic IP (DHCP)**

---

## Часть 3: Установка Podkop (VLESS + выборочная маршрутизация)

```bash
ssh root@192.168.1.1
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)
```

### Настройка в LuCI

**Services → Podkop**

1. **Тип подключения:** `proxy`
2. **Строка подключения:** вставь VLESS-ссылку:
   ```
   vless://UUID@СЕРВЕР:443?security=reality&sni=SNI&pbk=PUBLIC_KEY&sid=SHORT_ID#Название
   ```
3. **Список доменов:** `russia_inside`
4. Включи и сохрани

Дополнительные списки: `youtube`, `meta`, `discord`, `telegram`.

Торрент напрямую: в разделе **Protocol exclusions** выбери `bittorrent`.

---

## Часть 4: WireGuard-сервер для подключения снаружи

### Требования

- Белый IP от провайдера (проверить на 2ip.ru)
- Если IP динамический — настроить DDNS (No-IP, DynDNS — бесплатно)

### Установка WireGuard

```bash
opkg update
opkg install wireguard-tools kmod-wireguard luci-app-wireguard
```

### Генерация ключей

```bash
# Ключи сервера
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key

# Ключи клиента (телефона)
wg genkey | tee /etc/wireguard/client_private.key | wg pubkey > /etc/wireguard/client_public.key

# Посмотреть ключи
cat /etc/wireguard/server_private.key   # → SERVER_PRIVATE
cat /etc/wireguard/server_public.key    # → SERVER_PUBLIC
cat /etc/wireguard/client_private.key   # → CLIENT_PRIVATE
cat /etc/wireguard/client_public.key    # → CLIENT_PUBLIC
```

### Настройка WireGuard в LuCI

**Network → Interfaces → Add new interface**
- Имя: `wg0`
- Протокол: `WireGuard VPN`

Заполни:
- Private Key: `SERVER_PRIVATE`
- Listen Port: `51820`
- IP адрес: `10.0.0.1/24`

Добавь peer (телефон):
- Public Key: `CLIENT_PUBLIC`
- Allowed IPs: `10.0.0.2/32`

### Настройка firewall

**Network → Firewall → Add new zone:**
- Имя: `wireguard`
- Интерфейс: `wg0`
- Input/Forward/Output: `Accept`

Добавь forwarding: `wireguard → lan` и `wireguard → wan`

### Конфиг для телефона

Создай файл `/tmp/client.conf`:

```ini
[Interface]
PrivateKey = CLIENT_PRIVATE
Address = 10.0.0.2/24
DNS = 10.0.0.1

[Peer]
PublicKey = SERVER_PUBLIC
Endpoint = ТВОЙ_IP_ИЛИ_DDNS:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

Сгенерировать QR-код для импорта в приложение WireGuard на телефоне:
```bash
opkg install qrencode
qrencode -t ansiutf8 < /tmp/client.conf
```

### Проброс порта на Archer AX55

**Advanced → NAT Forwarding → Port Forwarding:**
- Внешний порт: `51820` (UDP)
- Внутренний IP: `192.168.1.1` (R3S)
- Внутренний порт: `51820`

---

## Проверка

### Дома (через Wi-Fi)
```bash
curl https://ifconfig.me  # IP VPN-сервера для заблокированных сайтов
```

### На улице (через мобильный интернет)
1. Включи WireGuard на телефоне
2. Зайди на `ifconfig.me` — должен показать домашний IP
3. Зайди на заблокированный сайт — должен открыться через VLESS

---

## Логика маршрутизации

| Трафик | Откуда | Путь |
|--------|--------|------|
| Заблокированные сайты | Дома | Через VLESS |
| Обычные сайты | Дома | Напрямую |
| Любой трафик | Телефон на улице | WireGuard → R3S → Podkop |
| BitTorrent | Любое устройство | Напрямую |

---

## Устранение проблем

**Podkop не запускается:**
```bash
logread | grep podkop
logread | grep sing-box
```

**LuCI не показывает Podkop:**
```bash
rm -f /var/luci-indexcache* /tmp/luci-indexcache*
```

**WireGuard не подключается снаружи:**
- Проверь проброс порта на AX55
- Проверь белый IP: `curl https://ifconfig.me` с R3S должен совпадать с тем что на AX55
- Порт открыт: `ss -ulnp | grep 51820`

**Телефон подключён к WireGuard но сайты не открываются:**
- Проверь DNS в конфиге клиента: должен быть `10.0.0.1`
- Проверь forwarding в firewall: `wireguard → wan`
