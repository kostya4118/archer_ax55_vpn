# NanoPi R3S LTS + OpenWrt 25.12 + AmneziaWG + Podkop

Рабочая инструкция по превращению NanoPi R3S LTS в VPN-шлюз с выборочной
маршрутизацией: заблокированные ресурсы уходят в туннель AmneziaWG,
российские сайты и всё остальное идут напрямую.

Archer AX55 остаётся в схеме как точка доступа Wi-Fi и не перепрошивается.

## Схема сети

```
Провайдер ──▶ WAN (eth0) │ NanoPi R3S │ LAN (eth1) ──▶ Archer AX55 (режим точки доступа) ──▶ устройства
                         │            │
                         │   awg0 ────┼──▶ сервер Amnezia ──▶ заблокированные ресурсы
                         │            │
                         │  Podkop / sing-box решает, что куда
```

Маршрутизацией управляет Podkop: он подменяет DNS-ответы для доменов из
списков на адреса `198.18.0.0/15` (FakeIP) и заворачивает трафик к ним в
туннель. Всё, чего нет в списках, идёт мимо VPN.

## Что понадобится

- NanoPi R3S или R3S LTS
- MicroSD 8+ ГБ
- Два патч-корда
- Сервер Amnezia с настроенным протоколом AmneziaWG
- Mac или Linux для записи образа

---

## Часть 1. Прошивка

### Важно про R3S LTS

R3S LTS — отдельная ревизия платы (добавлены HDMI, MIPI-DSI, разъём
динамика, кнопка питания), вышедшая в июле 2025. Отдельного профиля в
OpenWrt для неё **нет**: в `target/linux/rockchip/image/armv8.mk` определён
только `friendlyarm_nanopi-r3s`.

Тем не менее образ обычного R3S на LTS загружается и работает — SoC тот же
RK3566, device tree подходит. Оба порта Ethernet поднимаются, плата
определяется как `friendlyarm,nanopi-r3s`. Проверено на 24.10.0 и 25.12.5.

Если бы не завелось, запасной путь — FriendlyWrt от производителя:
[Actions-FriendlyWrt/releases](https://github.com/friendlyarm/Actions-FriendlyWrt/releases),
файл `R3S-Series-FriendlyWrt-24.10.img.gz` (образы там названы по сериям, а
не по отдельным платам, поэтому поиск по `r3s-lts` ничего не даёт).

### Скачать и записать образ

Готового initramfs-образа для R3S не публикуют — на карту пишется сразу
sysupgrade-образ, с него плата и работает.

```bash
cd ~/Downloads
curl -LO https://downloads.openwrt.org/releases/25.12.5/targets/rockchip/armv8/openwrt-25.12.5-rockchip-armv8-friendlyarm_nanopi-r3s-squashfs-sysupgrade.img.gz
```

Найти карту и записать (macOS):

```bash
diskutil list                       # найти свою карту по размеру, например /dev/disk6
diskutil unmountDisk /dev/disk6
sudo sh -c "gunzip -c ~/Downloads/openwrt-25.12.5-*-sysupgrade.img.gz | dd of=/dev/disk6 bs=4M"
diskutil eject /dev/disk6
```

macOS после записи покажет «Подключённый диск нельзя прочитать» — это
нормально, он не понимает файловую систему OpenWrt. Нажать «Пропустить».

### Первый запуск

Вставить карту, соединить **LAN-порт R3S** с компьютером патч-кордом,
подать питание, подождать пару минут.

```bash
ssh root@192.168.1.1     # пароль пустой
```

Сразу задать пароль: `passwd`.

### Ключ SSH

В OpenWrt SSH-сервер — dropbear, ключи лежат не в `~/.ssh`:

```bash
cat ~/.ssh/id_ed25519.pub | ssh root@192.168.1.1 \
  "cat >> /etc/dropbear/authorized_keys && chmod 600 /etc/dropbear/authorized_keys"
```

### Проверка железа

```bash
ip link show                    # должны быть eth0 (WAN) и eth1 (LAN, в br-lan)
ubus call system board
```

---

## Часть 2. Подключение к провайдеру

### Клонирование MAC

Если провайдер привязывает выдачу адреса к MAC, проще подставить R3S адрес
старого роутера, чем просить перепривязку. WAN MAC у Archer AX55:
**Расширенная → Сеть → Состояние → WAN MAC-адрес**.

Начиная с OpenWrt 21.02 MAC задаётся **в секции устройства**, а не
интерфейса — `network.wan.macaddr` молча игнорируется:

```bash
SEC=$(uci show network | awk -F. "/\.name='eth0'/{print \$2; exit}")
uci set network.$SEC.macaddr='AA:BB:CC:DD:EE:FF'
uci commit network
reboot
```

Проверка: `ip link show eth0 | grep ether`.

При динамическом IP настраивать больше нечего — DHCP на WAN включён по
умолчанию. Для PPPoE:

```bash
uci set network.wan.proto='pppoe'
uci set network.wan.username='ЛОГИН'
uci set network.wan.password='ПАРОЛЬ'
uci commit network && /etc/init.d/network restart
```

Проверка:

```bash
ifstatus wan | grep -E '"up"|"address"'
ping -c 3 8.8.8.8
```

### Archer AX55 в режим точки доступа

**Расширенная → Система → Режим работы → Точка доступа.**

Это обязательный шаг, если LAN-подсети совпадают. Без него получается
двойной NAT, и Podkop видит весь трафик как исходящий от одного адреса
AX55 — правила по конкретным устройствам становятся невозможны.

После переключения AX55 получает адрес от R3S по DHCP. Чтобы закрепить его:

```bash
uci add dhcp host
uci set dhcp.@host[-1].name='ax55'
uci set dhcp.@host[-1].mac='AA:BB:CC:DD:EE:FE'   # LAN MAC роутера
uci set dhcp.@host[-1].ip='192.168.1.2'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

Адрес берётся вне DHCP-пула (пул начинается со `192.168.1.100`).

Кабели: провайдер → WAN R3S, LAN R3S → любой порт AX55.

---

## Часть 3. AmneziaWG

### Пакеты

`kmod-amneziawg` — модуль ядра, жёстко привязанный к конкретной сборке.
Версия пакета обязана совпадать с версией OpenWrt. Сборки берутся из
[Slava-Shchipunov/awg-openwrt](https://github.com/Slava-Shchipunov/awg-openwrt/releases).

В OpenWrt 25.12 пакетный менеджер — `apk`, файлы с расширением `.apk`
(в 24.10 был `opkg` и `.ipk`).

```bash
cd /tmp
BASE=https://github.com/Slava-Shchipunov/awg-openwrt/releases/download/v25.12.5

wget -O kmod-amneziawg.apk   $BASE/kmod-amneziawg_v25.12.5_aarch64_generic_rockchip_armv8.apk
wget -O amneziawg-tools.apk  $BASE/amneziawg-tools_v25.12.5_aarch64_generic_rockchip_armv8.apk

apk add --allow-untrusted ./kmod-amneziawg.apk ./amneziawg-tools.apk
```

Флаг `-O` обязателен: GitHub перебрасывает на подписанный URL хранилища, и
BusyBox `wget` иначе сохранит файл под именем из пути редиректа.

`--allow-untrusted` нужен потому, что пакеты собраны сторонним репозиторием.

Проверка:

```bash
modprobe amneziawg && lsmod | grep amneziawg
awg --version
```

### Про luci-proto-amneziawg

В штатных репозиториях 25.12 пакета нет (`apk search amneziawg` пуст), в
релизах awg-openwrt для этой версии тоже — только языковой пакет. Он нужен
лишь для того, чтобы протокол появился в выпадающем списке LuCI; через UCI
интерфейс настраивается полностью.

### Конфиг из Amnezia

В приложении: сервер → протокол AmneziaWG → поделиться подключением →
формат **AmneziaWG** (нативный `.conf`, не «Amnezia»).

Соответствие полей — точные имена опций можно посмотреть прямо в
protocol-скрипте: `grep -A40 'proto_amneziawg_init_config'
/lib/netifd/proto/amneziawg.sh`.

| `.conf` | UCI |
|---|---|
| `PrivateKey` | `private_key` |
| `Address` | `addresses` |
| `Jc` / `Jmin` / `Jmax` | `awg_jc` / `awg_jmin` / `awg_jmax` |
| `S1`–`S4` | `awg_s1`–`awg_s4` |
| `H1`–`H4` | `awg_h1`–`awg_h4` |
| `I1`–`I5` | `awg_i1`–`awg_i5` |
| `PublicKey` | `public_key` (в секции пира) |
| `PresharedKey` | `preshared_key` |
| `Endpoint` | `endpoint_host` + `endpoint_port` раздельно |

В AmneziaWG 2.0 значения `H1`–`H4` могут быть диапазонами вида
`1075176743-1725333805` — переносятся как есть.

### Интерфейс

```bash
uci -q delete network.awg0
uci set network.awg0=interface
uci set network.awg0.proto='amneziawg'
uci set network.awg0.private_key='ПРИВАТНЫЙ_КЛЮЧ'
uci add_list network.awg0.addresses='10.8.1.4/32'
uci set network.awg0.mtu='1420'

uci set network.awg0.awg_jc='6'
uci set network.awg0.awg_jmin='10'
uci set network.awg0.awg_jmax='50'
uci set network.awg0.awg_s1='16'
uci set network.awg0.awg_s2='114'
uci set network.awg0.awg_s3='45'
uci set network.awg0.awg_s4='6'
uci set network.awg0.awg_h1='1075176743-1725333805'
uci set network.awg0.awg_h2='1993921499-2024794657'
uci set network.awg0.awg_h3='2134227464-2145161654'
uci set network.awg0.awg_h4='2146137760-2146702190'
uci set network.awg0.awg_i1='<r 2><b 0x8580...>'
```

`I1` содержит пробелы и угловые скобки — только одинарные кавычки.

Строка `DNS` из конфига намеренно не переносится: DNS настраивает Podkop.

### Пир

Имя секции обязано быть `amneziawg_<имя интерфейса>` — protocol-скрипт ищет
её именно так (`config_foreach proto_amneziawg_setup_peer "amneziawg_${config}"`).

```bash
uci -q delete network.awgpeer
uci set network.awgpeer=amneziawg_awg0
uci set network.awgpeer.public_key='ПУБЛИЧНЫЙ_КЛЮЧ_СЕРВЕРА'
uci set network.awgpeer.preshared_key='PRESHARED_KEY'
uci add_list network.awgpeer.allowed_ips='0.0.0.0/0'
uci add_list network.awgpeer.allowed_ips='::/0'
uci set network.awgpeer.endpoint_host='1.2.3.4'
uci set network.awgpeer.endpoint_port='41607'
uci set network.awgpeer.persistent_keepalive='25'
uci set network.awgpeer.route_allowed_ips='0'
```

**`route_allowed_ips='0'` — ключевая строка.** Она запрещает создавать
маршрут по умолчанию через туннель. Без неё весь трафик уходит в VPN и
выборочность теряется: маршрутизацией должен управлять Podkop.

### Файрвол

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='awg'
uci add_list firewall.@zone[-1].network='awg0'
uci set firewall.@zone[-1].input='REJECT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci set firewall.@zone[-1].mtu_fix='1'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='awg'

uci commit network && uci commit firewall
/etc/init.d/network restart && /etc/init.d/firewall restart
```

### Проверка туннеля

```bash
ip addr show awg0
awg show
ping -c 3 -I awg0 1.1.1.1
```

В выводе `awg show` должна появиться непустая строка `latest handshake` и
трафик в обе стороны. Если байты только отправляются — сервер не отвечает,
почти всегда причина в опечатке в параметрах обфускации или неверном
`PresharedKey`.

`curl` в базовой поставке 25.12 нет, ставится отдельно: `apk add curl`.
Тогда доступна проверка выхода через туннель:

```bash
curl --interface awg0 -s https://ifconfig.me     # IP сервера Amnezia
```

---

## Часть 4. Podkop

```bash
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)
```

Установщик определяет пакетный менеджер сам (`command -v apk`), так что
работает и на 24.10, и на 25.12. OpenWrt 23.05 не поддерживается начиная с
Podkop 0.5.0.

Настройка в LuCI: **Services → Podkop**

1. **Тип подключения** → `VPN`
2. Интерфейс → `awg0`
3. **Списки сообщества** → `Russia inside`
4. **Service list** → при необходимости `youtube`, `meta`, `discord`, `telegram`
5. Сохранить и применить

Если пункт не появился в меню:

```bash
rm -f /tmp/luci-indexcache*
```

### Несколько каналов одновременно

Секции в Podkop независимы: у каждой свой исходящий канал и свои списки.
Это позволяет развести сервисы по разным VPN — например, основной трафик
через AmneziaWG, а YouTube через отдельный VLESS.

```
                    ┌─ main    (awg0, AmneziaWG) ──▶ russia_inside
Клиент ──▶ Podkop ──┤
                    ├─ youtube (VLESS)           ──▶ service list: youtube
                    └─ остальное ────────────────▶ напрямую
```

Вторая секция добавляется кнопкой внизу вкладки **Секции**. Для VLESS,
Shadowsocks, Trojan и Hysteria2 отдельный сетевой интерфейс не нужен —
достаточно типа `Proxy` и ссылки, sing-box поднимет исходящий сам. Для
второго туннеля AmneziaWG пришлось бы завести `awg1` со своей секцией пира
`amneziawg_awg1` и своей зоной файрвола.

**Порядок секций определяет приоритет.** Правила проверяются сверху вниз,
и срабатывает первое совпавшее — более специфичное не выигрывает у более
общего. Список `russia_inside` в секции `main` уже содержит домены YouTube,
поэтому отдельная секция под YouTube не сработает вообще, пока стоит ниже.
Лечится перестановкой:

```bash
uci reorder podkop.youtube=1     # сразу после settings, то есть перед main
uci commit podkop
/etc/init.d/podkop restart
uci show podkop | grep '=section'
```

Симптом характерный: секция настроена верно и включена, но трафик до неё
не доходит. Проверяется через Clash API — он показывает, какой канал
обслуживает каждое соединение:

```bash
curl -s http://192.168.1.1:9090/connections > /tmp/conn.json
grep -o '"host":"[^"]*"' /tmp/conn.json | sort -u
grep -o '"chains":\[[^]]*\]' /tmp/conn.json | sort | uniq -c
```

Ключ доступа Podkop по умолчанию не задаёт, авторизация не нужна. Та же
информация есть в панели YACD (`enable_yacd`), в форме подключения поле
**Secret** оставляется пустым.

На вкладке **Дашборд** видны все каналы с их типами, а кнопка
**Тестирование задержки** проверяет каждый отдельно. Подпись `Direct` под
интерфейсом в режиме VPN — это нормально: Podkop создаёт исходящий типа
`direct`, привязанный к интерфейсу, а туннелирование выполняет сам
AmneziaWG на уровне сети.

### Резервный канал при отказе

Секции друг друга не подстраховывают: если канал секции умер, совпавшие с
ней домены просто перестают открываться — отката на другую секцию нет.
Встроенный `urltest` переключается только между прокси-ссылками, интерфейс
VPN в него подставить нельзя (тип подключения `vpn` обрабатывается
отдельной веткой кода).

Обходится тем же порядком секций: опущенная ниже `main` секция перестаёт
срабатывать, и домены достаются основному каналу. Настройки при этом
сохраняются, переключение обратимо одной командой.

Clash API даёт готовую проверку живости канала — тот же запрос, что стоит
за кнопкой «Тестирование задержки»:

```bash
curl -s "http://192.168.1.1:9090/proxies/youtube-out/delay?timeout=8000&url=http://cp.cloudflare.com/generate_204"
# {"delay":480} — канал жив
```

Адрес берётся из `external_controller` в конфиге sing-box; на loopback
контроллер не слушает. Имена каналов — `curl -s http://192.168.1.1:9090/proxies`.

Сторожевой скрипт `/root/yt-failover`:

```sh
#!/bin/sh
API="http://192.168.1.1:9090"
NAME="youtube-out"
FAILS="/tmp/yt-failover.fails"
THRESHOLD=5

alive() {
    curl -s --max-time 12 \
        "$API/proxies/$NAME/delay?timeout=8000&url=http://cp.cloudflare.com/generate_204" \
        | grep -q '"delay"'
}

first="$(uci show podkop | grep '=section' | head -1 | cut -d. -f2 | cut -d= -f1)"
fails="$(cat $FAILS 2>/dev/null || echo 0)"

if alive; then
    echo 0 > "$FAILS"
    want="youtube"
else
    fails=$((fails + 1))
    echo "$fails" > "$FAILS"
    if [ "$fails" -ge "$THRESHOLD" ]; then want="main"; else want="$first"; fi
fi

[ "$first" = "$want" ] && exit 0

case "$want" in
    youtube) uci reorder podkop.youtube=1 ;;
    main)    uci reorder podkop.youtube=2 ;;
esac

uci commit podkop
/etc/init.d/podkop restart
logger -t yt-failover "YouTube switched to: $want"
```

```bash
chmod +x /root/yt-failover
echo '* * * * * /root/yt-failover' >> /etc/crontabs/root
/etc/init.d/cron restart
```

### Ручное переключение

Сторож проверяет канал каждую минуту и приводит порядок секций к своему
решению, поэтому переставленную вручную секцию он вернёт обратно почти
сразу. Чтобы этого не происходило, он пропускает проверку при наличии
файла-признака:

```bash
sed -i '/^THRESHOLD=5$/a [ -f /tmp/yt-manual ] && exit 0' /root/yt-failover
```

```bash
# переключить вручную и зафиксировать
touch /tmp/yt-manual
uci reorder podkop.youtube=2 && uci commit podkop && /etc/init.d/podkop restart

# вернуть автоматику
rm -f /tmp/yt-manual && /root/yt-failover
```

Файл лежит в `/tmp`, поэтому после перезагрузки автоматический режим
восстанавливается сам — забытое ручное переключение не станет постоянным.

Удобно повесить это на кнопки: `apk add luci-app-commands` добавляет пункт
**System → Custom Commands**, где каждой команде соответствует кнопка с
выводом результата. `luci-app-ttyd` даёт полноценный терминал в браузере
(**System → Terminal**) — оба пакета выполняют команды от имени root, так
что наружу их открывать нельзя.

Порог обязателен: каждое переключение перезапускает Podkop и обрывает
трафик секунд на двадцать, так что метания из-за разовой сетевой икоты
обошлись бы дороже самой проблемы. Пять неудач при проверке раз в минуту
дают около пяти минут до переключения — столько же, сколько две проверки с
пятиминутным интервалом, но набранных из пяти независимых измерений, а не
двух. Возврат делается сразу при первом успехе, то есть в пределах минуты.

Проверка ждёт ответа до 12 секунд, так что при ежеминутном запуске соседние
запуски не накладываются. Если канал начнёт стабильно упираться в таймаут,
скрипт сочтёт это отказом — тогда стоит поднять `timeout` в запросе.

Проверить, не дожидаясь реального сбоя, можно подставным именем канала:

```bash
sed -i 's|NAME="youtube-out"|NAME="nonexistent"|' /root/yt-failover
/root/yt-failover; /root/yt-failover
uci show podkop | grep '=section'      # main должна стать первой
logread -e yt-failover
sed -i 's|NAME="nonexistent"|NAME="youtube-out"|' /root/yt-failover
/root/yt-failover
```

### Торренты мимо VPN

Многие VLESS/VPN-серверы запрещают BitTorrent. Отдельного переключателя по
протоколу в Podkop нет, но он и не нужен: в туннель попадает только то, что
перечислено в списках, всё остальное идёт напрямую. Соединения с пирами
адресуются по IP и ни в один список не входят, поэтому торрент-трафик
обходит VPN сам собой.

Это отличается от ручного конфига sing-box, где по умолчанию всё уходит в
туннель и торренты приходится вынимать явным правилом
`{"protocol": "bittorrent", "outbound": "direct"}` первым в списке `rules`.

Проверка — счётчики туннеля во время активной закачки:

```bash
awg show | grep transfer
sleep 30
awg show | grep transfer
```

Если домен трекера всё же входит в один из списков (заблокированные трекеры
есть в `russia_inside`), через VPN пойдут только анонсы, обмен с пирами
останется прямым. Чтобы вынуть и анонсы, добавляется вторая секция с типом
**Exclusion** и доменами трекера — секции обрабатываются отдельно, и
`Exclusion` имеет приоритет над списками основной секции.

---

## Часть 5. AdGuard Home

Блокировка рекламы и трекеров на уровне DNS — сразу для всех устройств,
включая телевизоры и умную технику, куда блокировщик не поставить.

AdGuard Home встаёт **позади** sing-box, а не перед ним:

```
Клиент → dnsmasq → sing-box (FakeIP для списков) → AdGuard Home → внешний DNS
```

Домены из списков получают подставной адрес и уходят в туннель, не доходя
до AGH; всё остальное проходит через фильтры. Порт 53 у dnsmasq при этом не
отбирается — AGH слушает на отдельном адресе внутри роутера.

### Установка

```bash
apk add adguardhome
/etc/init.d/adguardhome enable
/etc/init.d/adguardhome start
```

Мастер на `http://192.168.1.1:3000`. В разделе **DNS-сервер** он предложит
только адреса существующих интерфейсов, и на «Все интерфейсы» выдаст
`bind: address already in use` — порт 53 занят dnsmasq. Нужный адрес в
списке не появится, поэтому мастер проходится с временным портом `5353`, а
адрес правится в конфиге.

### Конфигурация

```bash
/etc/init.d/adguardhome stop
grep -n -A8 '^dns:' /etc/adguardhome/adguardhome.yaml
```

Привести секцию к виду:

```yaml
dns:
  bind_hosts:
    - 127.0.0.10
  port: 53
  ratelimit: 0
```

`127.0.0.10` — рекомендация документации Podkop. Не `127.0.0.42` (там
резолвер sing-box) и не `127.0.0.53` (зарезервирован системой). Конфликта с
dnsmasq нет: тот слушает на конкретных адресах интерфейсов, а не на всех.

`ratelimit: 0` обязателен. По умолчанию стоит 20 запросов в секунду **с
одного адреса**, а в этой схеме все запросы приходят от sing-box, то есть с
единственного — в лимит упёрлась бы вся сеть разом.

```bash
/etc/init.d/adguardhome start
netstat -lnp 2>/dev/null | grep '127.0.0.10:53'
nslookup ya.ru 127.0.0.10
```

### Переключение Podkop

Только после того, как AGH ответил — иначе разрешение имён встанет для всей
сети.

```bash
uci set podkop.settings.dns_type='udp'
uci set podkop.settings.dns_server='127.0.0.10'
uci commit podkop
/etc/init.d/podkop restart
```

Откат: вернуть `dns_server` на публичный резолвер.

### Проверка

```bash
nslookup youtube.com          # 198.18.x.x — перехвачен, идёт в туннель
nslookup doubleclick.net      # 0.0.0.0 — заблокирован фильтром
nslookup ya.ru                # настоящий адрес — идёт напрямую
```

Плюс **Журнал запросов** в интерфейсе AGH.

### Чего это не даёт

Рекламу в YouTube убрать нельзя: она отдаётся с тех же серверов, что и
видео, и блокировка домена ломает воспроизведение. Помогает только выход
через российский адрес — Google не показывает рекламу российским зрителям с
марта 2022.

Домены из списков Podkop не фильтруются вовсе — они получают FakeIP, не
доходя до AGH. На практике несущественно: в списках сервисы для обхода
блокировок, а не рекламные сети.

AGH становится критичным звеном: если он упадёт, перестанут разрешаться все
имена, кроме тех, что попали в списки.

## Проверка результата

С клиента (не с роутера):

```bash
scutil --dns | grep nameserver | head    # macOS: должен быть 192.168.1.1
nslookup youtube.com                     # ждём 198.18.x.x — FakeIP
nslookup ya.ru                           # ждём настоящий адрес
curl -s https://ifconfig.me              # ждём IP провайдера, не сервера VPN
```

Правильная картина: домены из списков резолвятся в `198.18.0.0/15` и идут в
туннель, остальные — напрямую, поэтому внешний IP остаётся провайдерским.

---

## Грабли

**`scp` не работает: `/usr/libexec/sftp-server: not found`**
В dropbear нет SFTP, а современный `scp` по умолчанию работает поверх него.
Помогает флаг `-O` (старый протокол) либо загрузка файла прямо на роутер
через `wget`.

**Клиент не использует роутер как DNS**
Если на устройстве прописан внешний DNS (`8.8.8.8` и подобные), Podkop не
увидит запрос и не подменит ответ — механизм не включится вообще. Убрать
ручной DNS, оставить получение по DHCP. Побочный симптом: `NXDOMAIN` на
заблокированных доменах — это ТСПУ подменяет ответ по пути к публичному
резолверу.

**`/etc/init.d/podkop status` показывает `not running`**
Podkop — генератор конфигурации и правил, а не демон. Постоянно работающий
процесс здесь один: `pgrep -f sing-box`, `service sing-box status`.

**Валидность конфига sing-box**

```bash
sing-box check -c /etc/sing-box/config.json    # молчит = всё в порядке
logread -e podkop | tail -30
logread -e sing-box | tail -30
```

**Сайт не открывается — как отличить причину**

| Симптом | Причина | Решение |
|---|---|---|
| `Connection reset by peer` через туннель, напрямую работает | Сервис не принимает адреса дата-центров или блокирует по географии | Секция `Exclusion` с его доменами |
| Зависание без ответа, обрыв по таймауту | MTU: крупные пакеты теряются | Уменьшить `mtu` на интерфейсе туннеля до 1280 |
| `NXDOMAIN` или подменённый ответ | Запрос ушёл мимо роутера, ТСПУ подменил ответ | Убрать ручной DNS на клиенте |
| В одном браузере работает, в другом нет | DNS поверх HTTPS в обход системного | Выключить Secure DNS в браузере |

Проверять всегда с роутера, отделяя туннель от прямого пути:

```bash
curl -sI https://САЙТ --max-time 10 | head -3                    # напрямую
curl --interface awg0 -sI https://САЙТ --max-time 10 | head -3   # через туннель
```

Браузер для диагностики не годится: Safari кеширует агрессивно и держит
соединения, пока процесс жив. Прежде чем делать выводы — `⌘Q`,
`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`, при
упорстве ещё и `rm ~/Library/Cookies/HSTS.plist` при закрытом Safari.

**Браузеры со своим DNS**

Chrome и Firefox умеют резолвить имена через DoH мимо системного DNS. Такой
браузер целиком выпадает из-под Podkop: заблокированные сайты в нём не
откроются, зато откроются те, что вынесены в `Exclusion`. Расхождение
поведения между браузерами — верный признак. Выключается в Chrome
(Безопасность → Использовать безопасный DNS-сервер), в Firefox
(Приватность → DNS через HTTPS), на Android — «Частный DNS». На iOS тот же
эффект даёт iCloud Private Relay.

**Ошибка в статической привязке роняет всю сеть**

dnsmasq обслуживает и DHCP, и DNS, поэтому неверная запись в `config host`
не даёт ему стартовать — и клиенты остаются без адресов и без разрешения
имён. Выглядит как полный отказ сети, хотя роутер работает.

Валят конфигурацию, например, MAC с лишним символом (`378:F2:...` вместо
`78:F2:...`) или имя с пробелами — в поле `name` хранится имя хоста, пробелы
в нём недопустимы.

Поэтому после правки привязок перезапуск делается с проверкой:

```bash
uci commit dhcp
/etc/init.d/dnsmasq restart && /etc/init.d/dnsmasq status   # ждём running
logread -e dnsmasq | tail -10
```

Восстановление, когда адрес уже не выдаётся: прописать на компьютере
статические настройки (`192.168.1.50/24`, шлюз и DNS `192.168.1.1`) и зайти
по SSH. Через точку доступа это работает так же, как по кабелю — в режиме
моста она не маршрутизирует и находится в том же сегменте.

```bash
uci show dhcp | grep host
uci delete dhcp.@host[-1]
uci commit dhcp
/etc/init.d/dnsmasq restart
```

**После такого падения перезагрузи роутер целиком.** Podkop реагирует на
изменения dnsmasq своими триггерами, и при аварийном перезапуске правила
nftables, перехват DNS и привязки FakeIP расходятся с конфигурацией.
Симптом — часть сервисов работает, а часть нет; у Telegram это заметно
раньше всего, поскольку он подключается к дата-центрам по адресам и зависит
не от перехвата доменов, а от правил для подсетей.

**Мало места на overlay**
См. отдельную часть ниже — штатный образ отдаёт под систему около 100 МБ
независимо от размера карты.

---

## Часть 6. Расширение раздела на всю карту

Образ размечает под систему ~104 МБ, остальные гигабайты карты остаются
неразмеченными. Podkop с sing-box занимают почти всё это место, так что
запас исчерпывается быстро.

Устройство: раздел 2 содержит squashfs (только чтение), а в его хвосте
лежит overlay, подключённый петлёй `/dev/loop0`. Расширение — два действия:
раздвинуть раздел, затем растянуть файловую систему внутри.

### Резервная копия

```bash
sysupgrade -b /tmp/backup.tar.gz
```
```bash
scp -O 'root@192.168.1.1:/tmp/backup-*.tar.gz' ~/Downloads/
```

Кавычки обязательны — иначе zsh попытается раскрыть `*` локально.

### Разметка

```bash
apk add parted losetup resize2fs
cat /proc/partitions          # определить устройство карты: mmcblk0 или mmcblk1
```

```bash
parted -s /dev/mmcblk1 resizepart 2 100%
parted -s /dev/mmcblk1 print
reboot
```

Начало раздела не меняется, сдвигается только граница конца — данные не
затрагиваются. Предупреждение о занятом разделе ожидаемо: ядро перечитает
таблицу при загрузке.

### Файловая система

После перезагрузки `loop0` уже покрывает весь раздел, но файловая система
внутри осталась прежнего размера.

```bash
losetup -a
# /dev/loop0: [0021]:13 (/mmcblk1p2), offset 3735552
```

**Сначала выяснить тип** — от него зависит всё дальнейшее:

```bash
mount | grep loop0
```

Если `ext4` — достаточно `resize2fs /dev/loop0`, он умеет расти онлайн.

Если **f2fs** (так в 25.12 на rockchip), `resize2fs` выдаст
`Bad magic number in super-block`, а `resize.f2fs` откажется работать со
смонтированной файловой системой. Обход — вторая петля на тот же участок
карты, при том что первая остаётся смонтированной под `/overlay`:

```bash
apk add f2fs-tools

LOOP2=$(losetup -f)
losetup -o 3735552 $LOOP2 /dev/mmcblk1p2    # смещение из losetup -a

fsck.f2fs -f $LOOP2
mount $LOOP2 /mnt && umount $LOOP2
resize.f2fs $LOOP2

reboot
```

`mount`/`umount` в середине нужны, чтобы f2fs проиграл журнал и закрыл
контрольную точку — иначе `resize.f2fs` сочтёт файловую систему грязной.

**После `resize.f2fs` — сразу перезагрузка, ничего не записывая.**
Смонтированный overlay держит в памяти прежнюю разметку, и любая запись
разойдётся с тем, что уже лежит на карте.

Версия `f2fs-tools` имеет значение: в ветке 1.14.x ресайз падал с
`more segment needed`. На 1.16.0 отрабатывает.

Проверка: `df -h /overlay`.

### Запасной вариант

Если ресайз не удался, overlay пересоздаётся с нуля:

```bash
firstboot && reboot
```

fstools отформатирует его заново по размеру нового раздела. Настройки
возвращаются из бэкапа (`sysupgrade -r` или **System → Backup/Flash
Firmware → Restore**), пакеты придётся установить заново.

---

## Что осталось за рамками

**Доступ снаружи (WireGuard-сервер на R3S).** Требует белого IP. Если
провайдер выдаёт адрес из диапазона `100.64.0.0/10` — это CGNAT, входящие
соединения невозможны, и DDNS не помогает (он решает проблему меняющегося
адреса, а не отсутствия публичного). Варианты: заказать белый IP у
провайдера либо поднять WireGuard на VPS и подключать к нему и R3S, и телефон.
