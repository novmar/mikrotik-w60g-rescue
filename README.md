# MikroTik 60GHz: záchrana pojítka, kterému po upgradu zmizelo rádio

Po upgradu RouterOS 6.x → 7.x se 60GHz pojítko (nRAY 60G, Cube 60G ac, LHG 60G,
wAP 60G) **tváří jako mrtvé** — neodpovídá na ping, protějšek ho nevidí ani přes
MNDP. Ve skutečnosti běží dál, jen mu chybí ovladač rádia: balíček `wireless`
na krabici není nebo zůstal `disabled`, takže `/interface w60g` vůbec neexistuje.

A protože 60GHz spoj je u takové krabice **jediná cesta do sítě**, nemá jak dát
o sobě vědět. Zvenčí je to k nerozeznání od cihly.

```
/interface w60g print
  no such command or directory (w60g)

/system package print
  # NAME      VERSION
  0 routeros  7.23.7
  1 X wireless  7.23.7            <-- tady to je
```

---

## Proč se to děje

Od **RouterOS 7.13** nejsou ovladače starého wirelessu **a 60GHz** součástí
balíčku `routeros`, ale samostatného balíčku `wireless`
([changelog 7.13](https://cdn.mikrotik.com/routeros/7.13/CHANGELOG),
[Packages](https://manual.mikrotik.com/docs/getting-started/installation-and-upgrade/packages/)).

Automatická konverze, která `wireless` doplní, se spouští **jen při upgradu
z verze 7.12**. Změna je schovaná v hlavičce changelogu 7.13 a v žádném
pozdějším changelogu se neopakuje:

> Upgrade from v7.12 to v7.13 or later versions must be done through 7.12 in
> order to convert wireless packages automatically. Fresh installation with
> Netinstall or manual package installation works in the same manner as always.

**Takže kdo skočí z 6.49 rovnou na 7.2x — ručně nahraným NPK nebo hromadným
nástrojem — konverzní krok přeskočí a rádio zmizí.** Oficiální stránka
[Upgrading to v7](https://help.mikrotik.com/docs/spaces/ROS/pages/115736772/Upgrading+to+v7)
přitom u wirelessu tvrdí „OK, no extra steps are required".

Potvrzuje to i KB
[Missing wireless or wifi interface after update](https://help.mikrotik.com/docs/spaces/RKB/pages/280657934/Missing+wireless+or+wifi+interface+after+update):

> If you upgraded a device manually, you also have to upload also corresponding
> wireless package — for legacy wireless (and 60ghz) devices, it is a *wireless*
> package. … RouterOS and the corresponding wireless package must be the same version.

Stejný případ na fóru:
[Upgraded brand new nRAY 60G master and lost all signs of W60G radio](https://forum.mikrotik.com/t/upgraded-brand-new-nray-60g-master-and-lost-all-signs-of-w60g-radio/172827).

---

## Rychlý postup

```bash
git clone https://github.com/novmar/mikrotik-w60g-rescue.git
cd mikrotik-w60g-rescue
./fix-w60g.sh 10.0.0.2
```

Dostane IP, zbytek si zjistí sám: verzi RouterOS, architekturu, stav balíčku,
místo na flash. Stáhne správné NPK, dopraví ho na krabici, rebootuje a na konci
ověří, že spoj naběhl. Potřebuje `bash`, `curl`, `jq` a na krabici zapnutou
službu `www` (REST API, port 80).

Jen se podívat, nic neměnit:

```bash
./fix-w60g.sh 10.0.0.2 --probe
```

Projít síť a najít postižené krabice:

```bash
./find-broken.sh 10.0.0.0/16
```

```
10.0.82.134   nekde2jinam     LHG 60G      7.24.5   spoj OK (rssi -49)
10.0.82.154   nekde2tam       LHG 60G      7.24.5   !! SPOJ DOLE
10.0.17.154   RouterOS        Cube 60G ac  7.24.5   !! RADIO CHYBI - balicek wireless je VYPNUTY
```

Návratové kódy `fix-w60g.sh`: `0` = v pořádku / opraveno, `1` = chyba,
`2` = na dálku to nejde (viz [Když to přes síť nejde](#když-to-přes-síť-nejde)).

### Přihlašovací údaje

Skripty **žádné heslo neobsahují a nikam ho neukládají.** Buď se zeptají, nebo
si ho vezmou z proměnné prostředí:

```bash
MT_PASSWORD='...' ./fix-w60g.sh 10.0.0.2 --yes
```

Uživatel je výchozí `admin`, jiný přes `-u`. Při předání proměnnou pozor na
historii shellu.

---

## Jak poznat, že jde přesně o tuhle závadu

Na krabici, na kterou se dostaneš:

```
/system package print           → wireless s příznakem X, nebo v seznamu vůbec není
/interface print                → chybí wlan60-1
/interface bridge port print    → v bridgi visí osiřelý port *1 (odkaz na zmizelé rozhraní)
/log print                      → "Missing wireless driver package, please install it"
```

**Pozor na dvojí význam `disabled`.** Od 7.18 RouterOS vypisuje i balíčky, které
na krabici vůbec nejsou — jsou jen k dispozici na serveru
([CLI reference](https://manual.mikrotik.com/docs/cli-reference/system/package/)):

| příznak | význam | co s tím |
|---|---|---|
| `X` + vyplněná `version`/`build-time` | balíček leží na flashi, jen je vypnutý | odinstalovat a nahrát čistý |
| `XA` bez `version` | balíček na krabici **není**, je to nabídka ze serveru | nahrát NPK |

Z druhé strany spoje (na protějšku, který žije):

```
/interface w60g print           → running=false
/interface w60g station print   → running=false
/ip arp print                   → IP protějšku ve stavu failed
/interface bridge host print    → MAC protějšku tam není
```

**Z AP strany nejde odlišit „protějšek běží bez rádia" od „protějšek je mrtvý".**
Bez balíčku `wireless` zařízení nevysílá vůbec nic, takže oba stavy vypadají
identicky. Nedá se na to spoléhat při plánování výjezdu — rozlišíš to až kabelem.

---

## Ruční postup, když nechceš skript

Samotné `enable` **nestačí** — po rebootu se balíček vrátí do `disabled`
a do logu se nenapíše nic. Poškozený balíček je potřeba vyhodit a nahrát znovu:

```
/system package uninstall wireless
/system reboot
```

Po rebootu se uvolní místo (u nRAY zhruba 1,2 MB). Pak nahraj NPK **přesně té
verze, co na krabici běží** — mix verzí RouterOS odmítne:

```
/tool fetch url="https://download.mikrotik.com/routeros/7.24.5/wireless-7.24.5-arm64.npk" check-certificate=no
/system reboot
```

Když krabice nemá ven do internetu, nahraj soubor z notebooku:

```bash
curl -T wireless-7.24.5-arm64.npk ftp://10.0.0.2/ --user admin
```

> **NPK patří do kořene, ne do `flash/`.** Na krabicích s víc než 64 MB RAM je
> kořen `/file` RAM disk a instalátor hledá `.npk` jen tam; soubor v `flash/`
> jen trvale zabere místo a upgrade selže
> ([Files](https://manual.mikrotik.com/docs/system-information-and-utilities/files/),
> [forum](https://forum.mikrotik.com/t/lhg-60g-firmware-update-issue/178070)).
> `/tool fetch` i FTP upload do kořene ukládají správně.

Kontrola:

```
/system package print              → wireless bez příznaku X
/interface print                   → wlan60-1 je zpátky
/interface w60g monitor wlan60-1 once
/log print                         → "installed wireless-7.24.5"
```

**Konfigurace rádia přežije** — vrátí se včetně `mode`, `ssid`, `region`
i členství v bridgi. Nic se nepřekonfigurovává. Po navázání spoje hlásí obě
strany `connected=false` ještě 1–4 minuty, to je re-akvizice beamformingu.

### Správná architektura

`/system resource print` → `architecture-name`:

| deska | arch | balíček |
|---|---|---|
| nRAY 60G (nRAYG-60ad) | `arm64` | `wireless-<verze>-arm64.npk` |
| Cube 60G ac | `arm` | `wireless-<verze>-arm.npk` |
| LHG 60G, wAP 60G | `arm` | `wireless-<verze>-arm.npk` |

Jednotlivé balíčky jdou stáhnout přímo:

```
https://download.mikrotik.com/routeros/<verze>/wireless-<verze>-<arch>.npk
https://download.mikrotik.com/routeros/<verze>/routeros-<verze>-<arch>.npk
```

Celá sada je v `all_packages-<arch>-<verze>.zip` na <https://mikrotik.com/download>.
V adresáři [`npk/`](npk/) jsou přibalené už rozbalené balíčky pro verze, se
kterými se tenhle postup dělal.

---

## Když to přes síť nejde

Na krabicích s 16 MB flash může instalace skončit takhle:

```
/log print
  upgrade failed, free 301 kB of disk space
```

Důvod je asymetrie, kterou je potřeba znát:

- **Upgrade existujícího balíčku** (`routeros` → novější `routeros`) přepisuje
  starou instalaci. Projde i s 1,5 MB volného místa.
- **Přidání nového balíčku** (`wireless`, který tam dosud nebyl) potřebuje ve
  flashi jeho **plnou velikost navíc**. A to je ten problém.

Naměřeno na dvou stejných krabicích Cube 60G ac, obě RouterOS 7.24.5:

| | zdravá (kdysi Netinstall) | poškozená (upgrade z v6) |
|---|---|---|
| flash celkem | 16,00 MB | 16,00 MB |
| `routeros` | 11,73 MB | 11,73 MB |
| `wireless` | 1,79 MB | — chybí |
| volno | 0,91 MB | 1,54 MB |
| **mimo balíčky** | **1,64 MB** | **2,86 MB** |

Ten poslední řádek je jádro věci. Krabice upgradovaná z šestky si nese
**o 1,2 MB víc balastu** (konfigurace a zbytky po migraci) než čerstvě
nainstalovaná. Výsledek: `11,73 + 1,79 + 2,86 = 16,38 MB` se do 16,00 MB
prostě nevejde, zatímco zdravé krabici to vychází na 15,16 MB.

**Není to tedy o verzi balíčku, ale o tom, kolik balastu flash drží.**

Co funguje, v tomhle pořadí:

1. **Nainstalovat `routeros` + `wireless` NOVĚJŠÍ verze současně, jedním
   rebootem.** Instalátor přepisuje celou instalaci, takže se obojí vejde.
   Doloženo na 16MB LHG 60G (`routeros 7.16` + `wireless 7.16` najednou →
   14,5 z 16,0 MiB obsazeno,
   [forum](https://forum.mikrotik.com/t/lhg-60g-firmware-update-issue/178070)).
   ```bash
   scp routeros-7.24.6-arm.npk wireless-7.24.6-arm.npk admin@10.0.0.2:
   ```
   ```
   /file print detail where type="package"     # ověř shodnou verzi i architekturu
   /system reboot
   ```
   Háček: novější verze musí existovat. Když na krabici běží to nejnovější,
   co MikroTik vydal, není co přepsat.

2. **Nainstalovat STARŠÍ dvojici, která se do flash vejde.** Starší RouterOS
   je menší, a o ten rozdíl jde. Spouští se přes `downgrade`, instalují se
   zase obě najednou:
   ```
   /tool fetch url="https://download.mikrotik.com/routeros/7.16/routeros-7.16-arm.npk" check-certificate=no
   /tool fetch url="https://download.mikrotik.com/routeros/7.16/wireless-7.16-arm.npk" check-certificate=no
   /system package downgrade
   ```
   Ověřeno na té poškozené krabici z tabulky výše: `7.24.5` se nevešlo,
   **`7.16` ano** (`11,07 + 1,88` NPK → 13,57 MB nainstalováno, 16,43 MB
   obsazeno). Rádio se vrátilo i s konfigurací — včetně `bond` 60GHz + 5GHz,
   takže se nejdřív chytila 5GHz záloha a za pár sekund i 60GHz spoj
   (rssi -52, MCS 8, 2,31 Gbps).

   Velikosti NPK pro `arm`, ať je vidět, o co se hraje:

   | verze | routeros | wireless |
   |---|---|---|
   | 7.24.5 | 11,73 MB | 1,79 MB |
   | 7.22.1 | 11,69 MB | 1,80 MB |
   | 7.19.4 | 11,40 MB | 1,80 MB |
   | 7.16 | 11,07 MB | 1,88 MB |
   | 7.13.5 | 10,90 MB | 2,64 MB |

   `fix-w60g.sh` tohle dělá sám: spočítá balast, projde verze od nejnovější
   a vybere první, která se vejde.

   **Taková krabice pak musí ven z hromadných upgradů**, dokud ji někdo
   nenetinstalluje — příští upgrade na velkou verzi ji rozbije znovu.

3. **Uvolnit flash**: `/system package uninstall <nepotřebné>`, `/file remove`
   pro zálohy a supouty, logování přesměrovat z disku do paměti nebo na syslog.

4. **Netinstall.** Flash se formátuje, balast zmizí a vejde se i aktuální verze.

### Netinstall — co vzít s sebou

- [Netinstall](https://mikrotik.com/download) (Windows nebo Linux CLI)
- `routeros-<verze>-<arch>.npk` **i** `wireless-<verze>-<arch>.npk` ve stejném
  adresáři — Netinstall nainstaluje oba najednou
- ethernetový kabel přímo z notebooku do krabice

Postup: notebook staticky na `192.168.88.1/24` → v Netinstallu *Boot Server
enabled*, Client IP `192.168.88.2` → odpojit napájení → držet reset → zapojit
napájení → držet, dokud se krabice neobjeví v seznamu (10–20 s) → *Install*.

**Netinstall smaže konfiguraci**, takže si ji předem vyexportuj
(`/export file=zaloha`) nebo měj po ruce poznámky: IP, bránu, `ssid`, `mode`
(jedna strana `bridge`/`ap-bridge`, druhá `station-bridge`) a bridge porty.

### Netinstall na dálku

Od RouterOS 7.24beta1 umí Netinstall i jiný MikroTik
([Netinstall package](https://manual.mikrotik.com/docs/getting-started/installation-and-upgrade/netinstall/netinstall-package)):

```
/tool netinstall add interface=bridge1 mac-address=XX:XX:XX:XX:XX:XX \
    extra-packages=wireless version=7.24.5 ip-range=192.168.88.10-192.168.88.20 \
    keep-old-configuration=yes auto-reboot=reboot
```

Háček: vyžaduje to **L2 sousednost**. Pro krabici, jejíž jediná cesta je mrtvý
60GHz spoj, to zvenčí neuděláš. Dává to smysl jako **prevence** — mít na POPu
MikroTik s tímhle balíčkem a předem nastavené
`preboot-etherboot` ([RouterBOARD](https://manual.mikrotik.com/docs/hardware/routerboard)).

---

## Když krabice nejde vidět vůbec

Když je 60GHz spoj jediná cesta k boxu, nezbývá než k němu s kabelem. Na místě
**nejdřív poslouchej, co vysílá**, než začneš mačkat reset:

```bash
sudo tcpdump -nn -e -i <rozhraní>
```

Živý RouterOS se prozradí i bez IP:

- STP BPDU na `01:80:C2:00:00:00` každé 2 sekundy
- CDP na `01:00:0C:CC:CC:CC`, LLDP na `01:80:C2:00:00:0E`
- **MNDP** na UDP 5678 — z něj vyčteš identitu, verzi, uptime i IP adresu

Když tam tohle je, systém běží a Netinstall je zbytečný: stačí doinstalovat
balíček podle postupu výše.

Dvě pasti:

- **MNDP sken přes socket nic neukáže**, když má notebook routu na stejný rozsah
  přes VPN/WireGuard — jádro ty broadcasty zahodí kvůli `rp_filter`. Buď dej na
  rozhraní adresu ze segmentu krabice a nižší metriku než má tunel, nebo
  poslouchej přes `dumpcap`/`tcpdump`, které berou pakety před routingem.
- **Winbox umí MAC-telnet**, takže na krabici bez IP se dostaneš přes MAC adresu
  z MNDP (Neighbors → Connect To). Musíš být ve stejném broadcast segmentu.

---

## Prevence při hromadných upgradech

1. **Z v6 jdi přes 7.12.1.** Vestavěný updater ti z šestky stejně nabídne jen
   7.12.1; nech ho to udělat a teprve pak pokračuj na 7.13+. Konverze balíčků
   proběhne automaticky. Ruční skok z 6.49 rovnou na 7.2x je přesně to, co rádio
   zabíjí.
   ```
   /system package update set channel=upgrade
   /system package update check-for-updates
   /system package update install
   ```
2. **Když upgraduješ ručně, nahrávej `routeros` i `wireless` zároveň** a ve
   stejné verzi, do kořene.
3. **Po každém upgradu zkontroluj `/system package print` dřív, než odjedeš
   z lokality.** Dokumentace to uvádí jako povinný krok. Když `wireless` chybí,
   spoj je dole a od té chvíle se tam dostaneš jen kabelem.
4. **Upgraduj nejdřív vzdálený konec, pak bližší.** Opačné pořadí ti vzdálený
   konec odřízne.
5. **Po malých dávkách** a nikdy ne víc krabic na jedné management cestě
   současně.
6. **Bootloader až po RouterOS**, s rebootem mezi tím:
   ```
   /system routerboard upgrade
   /system reboot
   ```
7. **Na 16MB krabicích si předem ověř volné místo** (`/system resource print`).
   Pod ~2 MB už doinstalace balíčku neprojde a oprava na dálku nebude možná.
8. **Redundantní cesta se vyplatí.** Cube 60G ac má 5GHz rádio zdarma; MikroTik
   dokumentuje
   [failover 60G + 5G](https://manual.mikrotik.com/docs/wireless/w60g/fail-over-ptp-cli-example).

Co **nepomůže**: Safe mode (vrací jen konfiguraci, ne instalaci balíčků),
automatický rollback (RouterOS ho nemá), scheduler jako dead-man's switch
(krabice po selhání normálně běží, jen nevysílá).

---

## Co je v repozitáři

| soubor | k čemu |
|---|---|
| `fix-w60g.sh` | oprava jedné krabice; dostane IP a zbytek si zjistí sám |
| `find-broken.sh` | projde rozsah a vypíše, kde chybí rádio nebo je spoj dole |
| `npk/` | už stažené balíčky `wireless` pro arm a arm64 |

Balíčky v `npk/` jsou nezměněné soubory z download.mikrotik.com, přibalené pro
případ, že jsi na lokalitě bez internetu. Patří MikroTiku a platí pro ně jeho
licenční podmínky.

## Zdroje

- [Packages](https://manual.mikrotik.com/docs/getting-started/installation-and-upgrade/packages/) — rozdělení balíčků, `wireless`, uninstall
- [Upgrade](https://manual.mikrotik.com/docs/getting-started/installation-and-upgrade/upgrade) — kanály, mezikrok 7.12.1, pořadí s RouterBOOTem
- [Files](https://manual.mikrotik.com/docs/system-information-and-utilities/files/) — kořen vs `flash/`, RAM disk, výjimka pro `.npk`
- [KB: Missing wireless or wifi interface after update](https://help.mikrotik.com/docs/spaces/RKB/pages/280657934/Missing+wireless+or+wifi+interface+after+update)
- [KB: 7.13 new wireless packages](https://help.mikrotik.com/docs/spaces/RKB/pages/228655144/7.13+new+wireless+packages)
- [changelog 7.13](https://cdn.mikrotik.com/routeros/7.13/CHANGELOG) — hlavička „Notice"
- [W60G](https://manual.mikrotik.com/docs/wireless/w60g/) — monitor, align, scan
- [Netinstall package](https://manual.mikrotik.com/docs/getting-started/installation-and-upgrade/netinstall/netinstall-package) — vzdálený Netinstall z jiného MikroTiku
- [forum: nRAY 60G po upgradu bez w60g](https://forum.mikrotik.com/t/upgraded-brand-new-nray-60g-master-and-lost-all-signs-of-w60g-radio/172827)
- [forum: LHG 60G firmware update issue](https://forum.mikrotik.com/t/lhg-60g-firmware-update-issue/178070) — místo na flash, oba balíčky najednou
