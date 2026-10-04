#!/usr/bin/env bash
# oprava-na-miste.sh — výjezdový skript: kabel z notebooku do mrtvé krabice,
# spustit, zbytek obstará skript.
#
#   sudo ./oprava-na-miste.sh nodes/bohus488.conf
#   sudo ./oprava-na-miste.sh nodes/bohus488.conf -i enp6s0f4u2
#
# Co dělá:
#   1. nastaví si adresy na rozhraní (segment krabice + 192.168.88.x pro tovární stav)
#   2. 25 s poslouchá, co krabice vysílá  → pozná, v jakém je stavu
#   3. podle toho opraví: doinstalace balíčku wireless, nebo Netinstall
#   4. vrátí konfiguraci rádia a ověří, že spoj naběhl
#
# Potřebuje: bash, curl, jq, tcpdump (nebo dumpcap), ip, python3, root.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$HERE/../fix-w60g.sh"
MIRROR="https://download.mikrotik.com/routeros"
NI_VER="7.16"          # build Netinstallu, který s RouterBOOTem mluví spolehlivě
CACHE="${TMPDIR:-/tmp}/w60g-vyjezd"
POSLECH=25

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
die()  { printf '\nCHYBA: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "spusť pod rootem (nastavuje adresy a odposlouchává rozhraní)"
[ $# -ge 1 ] || die "použití: $0 <nodes/xxx.conf> [-i rozhraní]"

PROFIL="$1"; shift
[ -f "$PROFIL" ] || PROFIL="$HERE/$PROFIL"
[ -f "$PROFIL" ] || die "profil nenalezen"
# shellcheck disable=SC1090
. "$PROFIL"

IFACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--iface) IFACE="$2"; shift 2 ;;
    *) die "neznámý parametr: $1" ;;
  esac
done

for b in curl jq ip python3; do command -v "$b" >/dev/null || die "chybí $b"; done
SNIFF=""
command -v tcpdump >/dev/null && SNIFF=tcpdump
[ -z "$SNIFF" ] && command -v dumpcap >/dev/null && SNIFF=dumpcap
[ -n "$SNIFF" ] || die "chybí tcpdump ani dumpcap"

MT_USER="${MT_USER:-admin}"
if [ -z "${MT_PASSWORD:-}" ]; then
  read -rsp "heslo admina pro krabice: " MT_PASSWORD; echo
fi
export MT_PASSWORD
AUTH="$MT_USER:$MT_PASSWORD"

# --------------------------------------------- parametry rádia (bez hesel v gitu) --
# Pořadí: lokální soubor <profil>.secrets → živý protějšek → ruční zadání.
# Soubor .secrets vyrobíš doma skriptem ./priprav.sh, než vyjedeš.
if [ -f "$PROFIL.secrets" ]; then
  # shellcheck disable=SC1090
  . "$PROFIL.secrets"
  say "parametry rádia načteny z $(basename "$PROFIL").secrets"
elif [ -n "${PEER_IP:-}" ] && curl -s -m 6 -u "$AUTH" "http://$PEER_IP/rest/system/identity" >/dev/null 2>&1; then
  say "parametry rádia si beru z živého protějšku $PEER_IP"
  PEER_W="$(curl -s -m 10 -u "$AUTH" "http://$PEER_IP/rest/interface/w60g")"
  SSID="$(echo "$PEER_W"  | jq -r '.[0].ssid')"
  WPASS="$(echo "$PEER_W" | jq -r '.[0].password // ""')"
  REGION="$(echo "$PEER_W" | jq -r '.[0].region')"
  PEER_MODE="$(echo "$PEER_W" | jq -r '.[0].mode')"
  case "$PEER_MODE" in
    bridge|ap-bridge) MODE="station-bridge"; PUT_IN="" ;;
    *)                MODE="bridge"; PUT_IN="bridge" ;;
  esac
else
  say "protějšek není po ruce a .secrets soubor chybí — zadej parametry ručně:"
  read -rp  "  ssid: " SSID
  read -rsp "  heslo rádia (prázdné = žádné): " WPASS; echo
  read -rp  "  mode [station-bridge]: " MODE; MODE="${MODE:-station-bridge}"
  REGION="${REGION:-eu}"
fi
[ "$REGION" = "no-region-set" ] && REGION="eu"

say "┌───────────────────────────────────────────────"
say "│ $NODE — $POPIS"
say "│ cílová IP     : ${IP:-neznámá, doplní se z MNDP}${IP:+/$MASKA, brána $GW}"
say "│ rádio         : mode=$MODE ssid=$SSID"
say "│ protějšek     : $PEER_NAME ($PEER_IP)"
say "└───────────────────────────────────────────────"

# ------------------------------------------------------------- 1. rozhraní --
if [ -z "$IFACE" ]; then
  IFACE="$(ip -br link | awk '$2=="UP" && $1!="lo" && $1 !~ /^(wl|virbr|docker|tun|wg)/ {print $1}' | head -1)"
  [ -n "$IFACE" ] || die "nenašel jsem rozhraní s linkem — je kabel v krabici?"
fi
ip link show "$IFACE" >/dev/null 2>&1 || die "rozhraní $IFACE neexistuje"
step "Rozhraní $IFACE"
ip link set "$IFACE" up
sleep 2
ip -br link show "$IFACE" | grep -q LOWER_UP || say "  POZOR: na $IFACE není link. Zkontroluj kabel a napájení."

volna_adresa() {   # najde v segmentu adresu, která neodpovídá
  local base="$1" mask="$2" i
  for i in $(seq 4 60); do
    local kand="${base%.*}.$i"
    [ "$kand" = "$IP" ] && continue
    [ "$kand" = "$GW" ] && continue
    [ "$kand" = "$PEER_IP" ] && continue
    ping -c1 -W1 "$kand" >/dev/null 2>&1 || { echo "$kand/$mask"; return; }
  done
  echo ""
}

ip addr flush dev "$IFACE" 2>/dev/null
ip addr add 192.168.88.100/24 dev "$IFACE" 2>/dev/null
if [ -n "${LAPTOP_IP:-}" ]; then
  ip addr add "$LAPTOP_IP" dev "$IFACE" 2>/dev/null && say "  adresa $LAPTOP_IP nastavena"
elif [ -n "$IP" ]; then
  A="$(volna_adresa "$IP" "$MASKA")"
  [ -n "$A" ] && ip addr add "$A" dev "$IFACE" 2>/dev/null && say "  adresa $A nastavena"
fi
ip -br a show "$IFACE" | grep -q 192.168.88.100 && say "  192.168.88.100/24 nastavena (pro tovární stav krabice)" \
  || say "  POZOR: 192.168.88.100/24 se nastavit nepodařilo"

# --------------------------------------------------- 2. co krabice vysílá --
step "Poslouchám ${POSLECH}s, co krabice vysílá"
PCAP="$CACHE/odposlech.pcap"; mkdir -p "$CACHE"; rm -f "$PCAP"
if [ "$SNIFF" = tcpdump ]; then
  timeout $POSLECH tcpdump -nn -e -i "$IFACE" -w "$PCAP" 2>/dev/null &
else
  dumpcap -i "$IFACE" -a duration:$POSLECH -w "$PCAP" -q 2>/dev/null &
fi
SNIFF_PID=$!
sleep 3
# MNDP discovery — krabice odpoví i bez IP
python3 - "$IFACE" <<'PY' &
import socket, time, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for _ in range(8):
    try: s.sendto(b'\x00\x00\x00\x00', ('255.255.255.255', 5678))
    except OSError: pass
    time.sleep(2)
PY
wait $SNIFF_PID 2>/dev/null
sleep 1
if [ ! -s "$PCAP" ] && [ "$SNIFF" = tcpdump ] && command -v dumpcap >/dev/null; then
  say "  tcpdump nic nezachytil, zkouším dumpcap"
  dumpcap -i "$IFACE" -a duration:$POSLECH -w "$PCAP" -q 2>/dev/null
fi
[ -s "$PCAP" ] || { printf '' > "$PCAP.prazdny"; PCAP="$PCAP.prazdny"; say "  odposlech nic nezachytil"; }

ROZBOR="$(python3 - "$PCAP" <<'PY'
import struct, sys, socket as sk
TYPES={1:"mac",5:"identity",7:"version",8:"platform",10:"uptime",11:"softid",12:"board",15:"ipv6",16:"ifname",17:"ipv4"}
def mndp(b):
    out={}; i=4
    while i+4<=len(b):
        t,l=struct.unpack('!HH',b[i:i+4]); i+=4; v=b[i:i+l]; i+=l
        n=TYPES.get(t,str(t))
        if n=="mac": v=':'.join('%02X'%c for c in v)
        elif n=="ipv4" and l==4: v=sk.inet_ntoa(v)
        elif n=="uptime" and l==4: v=str(struct.unpack('<I',v)[0])+"s"
        else:
            try: v=v.decode('utf-8','replace')
            except Exception: v=v.hex()
        out[n]=v
    return out
def pakety(p):
    d=open(p,'rb').read(); out=[]
    if d[:4] in (b'\x0a\x0d\x0d\x0a',):            # pcapng
        off=0; endian='<'
        while off+12<=len(d):
            bt=int.from_bytes(d[off:off+4],'little'); bl=int.from_bytes(d[off+4:off+8],'little')
            if bt==6: 
                cl=int.from_bytes(d[off+20:off+24],'little'); out.append(d[off+28:off+28+cl])
            if bl<12: break
            off+=bl
    else:                                           # classic pcap
        off=24
        while off+16<=len(d):
            incl=struct.unpack('<I',d[off+8:off+12])[0]; off+=16
            out.append(d[off:off+incl]); off+=incl
    return out
stav={"mndp":None,"etherboot":False,"stp":0,"mac":None}
for p in pakety(sys.argv[1]):
    if len(p)<14: continue
    et=struct.unpack('!H',p[12:14])[0]; src=':'.join('%02X'%c for c in p[6:12]); b=p[14:]
    if et<=1500 and p[0:3]==b'\x01\x80\xc2': stav["stp"]+=1; stav["mac"]=src
    if et==0x0800 and len(b)>9 and b[9]==17:
        ihl=(b[0]&0xf)*4; sp,dp=struct.unpack('!HH',b[ihl:ihl+4])
        if dp==5678: stav["mndp"]=mndp(b[ihl+8:]); stav["mac"]=src
        if dp==67 and b'ARM__boot' in b or b'MMIPS_boot' in b or b'MIPSBE_boot' in b:
            stav["etherboot"]=True; stav["mac"]=src
print(repr(stav))
PY
)"
eval "STAV=\"$ROZBOR\""
python3 -c "
import sys
s=eval(sys.argv[1])
if s['mndp']:
    m=s['mndp']
    print('STAV=ziva')
    print('MNDP_IP=%s' % m.get('ipv4',''))
    print('MNDP_ID=%s' % m.get('identity',''))
    print('MNDP_VER=%s' % m.get('version','').split()[0])
    print('MNDP_BOARD=%s' % m.get('board',''))
    print('MNDP_MAC=%s' % m.get('mac',''))
elif s['etherboot']:
    print('STAV=etherboot'); print('MNDP_MAC=%s' % (s['mac'] or ''))
elif s['stp']:
    print('STAV=ziva_bez_mndp'); print('MNDP_MAC=%s' % (s['mac'] or ''))
else:
    print('STAV=ticho')
" "$ROZBOR" > "$CACHE/stav.env"
# shellcheck disable=SC1090
. "$CACHE/stav.env"

case "${STAV:-ticho}" in
  ziva)
    say "  krabice ŽIJE: ${MNDP_ID:-?} ${MNDP_VER:-?} na ${MNDP_BOARD:-?}, IP ${MNDP_IP:-žádná}, MAC $MNDP_MAC" ;;
  ziva_bez_mndp)
    say "  vidím STP rámce z $MNDP_MAC — systém běží, ale MNDP neodpovídá" ;;
  etherboot)
    say "  krabice je v ETHERBOOTU (volá BOOTP) — NAND boot selhal, MAC $MNDP_MAC" ;;
  ticho)
    say "  TICHO. Nic nevysílá." ;;
esac

# ------------------------------------------------------------- 3. oprava --
po_oprave() {
  local cil="$1"
  step "Kontrola spoje"
  curl -s -m 20 -u "$AUTH" -X POST -H 'Content-Type: application/json' \
       -d '{"numbers":"wlan60-1","once":""}' "http://$cil/rest/interface/w60g/monitor" \
    | jq -r '.[]? | "  connected=\(.connected) rssi=\(.rssi // "-") tx-mcs=\(."tx-mcs" // "-")"' 2>/dev/null
  for t in "$GW" "$PEER_IP"; do
    [ -n "$t" ] || continue
    n=$(curl -s -m 20 -u "$AUTH" -X POST -H 'Content-Type: application/json' \
        -d "{\"address\":\"$t\",\"count\":\"3\"}" "http://$cil/rest/ping" | jq -r '[.[]|select(.time)]|length' 2>/dev/null)
    say "  ping $t -> ${n:-0}/3"
  done
}

nastav_radio() {
  local cil="$1"
  step "Vracím konfiguraci rádia"
  local id
  id="$(curl -s -m 10 -u "$AUTH" "http://$cil/rest/interface/w60g" | jq -r '.[0].".id"')"
  [ -n "$id" ] && [ "$id" != null ] || { say "  rádio zatím není, přeskakuji"; return 1; }
  curl -s -m 10 -u "$AUTH" -X PATCH -H 'Content-Type: application/json' \
    -d "{\"mode\":\"$MODE\",\"ssid\":\"$SSID\",\"password\":\"$WPASS\",\"region\":\"$REGION\",\"frequency\":\"auto\",\"disabled\":\"false\"${PUT_IN:+,\"put-stations-in-bridge\":\"$PUT_IN\"}}" \
    "http://$cil/rest/interface/w60g/$id" | jq -c '{name,mode,ssid,region}'
  curl -s -m 10 -u "$AUTH" "http://$cil/rest/interface/bridge/port" | jq -e '.[]|select(.interface=="wlan60-1")' >/dev/null 2>&1 \
    || curl -s -m 10 -u "$AUTH" -X POST -H 'Content-Type: application/json' \
         -d '{"bridge":"bridge","interface":"wlan60-1"}' "http://$cil/rest/interface/bridge/port" >/dev/null
  say "  wlan60-1 je v bridgi"
}

case "${STAV:-ticho}" in

  ziva|ziva_bez_mndp)
    CIL="${MNDP_IP:-$IP}"
    [ -n "$CIL" ] || die "krabice běží, ale nevím na jaké IP. Zkus Winbox přes MAC ${MNDP_MAC:-?} (Neighbors)."
    step "Krabice je dosažitelná na $CIL — pouštím opravu balíčku"
    say ""
    MT_PASSWORD="$MT_PASSWORD" "$FIX" "$CIL" --yes -u "$MT_USER"
    RC=$?
    if [ $RC -eq 0 ]; then
      nastav_radio "$CIL" || true
      po_oprave "$CIL"
      step "HOTOVO"
      exit 0
    fi
    say ""
    say "Oprava balíčku neprošla (návratový kód $RC) — pokračuju Netinstallem."
    step "Přepínám krabici do etherbootu"
    curl -s -m 10 -u "$AUTH" -X POST -H 'Content-Type: application/json' \
      -d "{\"preboot-etherboot\":\"15s\",\"preboot-etherboot-server\":\"any\"}" \
      "http://$CIL/rest/system/routerboard/settings" >/dev/null
    curl -s -m 10 -u "$AUTH" -X POST -H 'Content-Type: application/json' -d '{}' \
      "http://$CIL/rest/system/reboot" >/dev/null
    say "  reboot odeslán, krabice se za chvíli ohlásí BOOTPem"
    sleep 40
    ;;

  ticho)
    cat <<EOF

Nic nevysílá. Postupně:
  1) odpoj napájení, počkej 10 s, zapoj   → pak spusť skript znovu
  2) když ani pak nic: drž RESET při zapnutí ~20 s, dokud nezhasne LED
     → krabice se zformátuje a naskočí do etherbootu, pak spusť skript znovu
  3) když ani pak nic, je to na výměnu

EOF
    exit 2
    ;;
esac

# ------------------------------------------------------- 4. Netinstall --
step "Netinstall"
ARCH="${ARCH:-}"
if [ -z "$ARCH" ]; then
  case "${MNDP_BOARD:-}" in
    *nRAY*|*60ad*) ARCH=arm64 ;;
    *Cube*|*LHG*|*wAP*) ARCH=arm ;;
    *) read -rp "  architekturu neznám (deska ${MNDP_BOARD:-?}). Zadej arm nebo arm64: " ARCH ;;
  esac
fi
VER="${VER:-7.24.5}"
say "  architektura $ARCH, instaluji RouterOS $VER + wireless $VER"

mkdir -p "$CACHE"; cd "$CACHE" || die "nelze do $CACHE"
for f in "routeros-$VER-$ARCH.npk" "wireless-$VER-$ARCH.npk"; do
  [ -s "$f" ] || { say "  stahuji $f"; curl -sS -m 600 -O "$MIRROR/$VER/$f" || die "stažení $f selhalo"; }
done
if [ ! -x "$CACHE/netinstall-cli" ]; then
  say "  stahuji netinstall $NI_VER (build 7.24.5 má vadné xid a zacyklí se)"
  curl -sS -m 600 -O "$MIRROR/$NI_VER/netinstall-$NI_VER.tar.gz" || die "stažení netinstallu selhalo"
  tar xzf "netinstall-$NI_VER.tar.gz" || die "rozbalení selhalo"
fi

RSC="$CACHE/obnova-$NODE.rsc"
{
  echo "# obnova $NODE, generováno $(date '+%Y-%m-%d %H:%M')"
  echo "/interface bridge add name=bridge protocol-mode=rstp"
  echo "/interface bridge port add bridge=bridge interface=ether1"
  [ -n "$IP" ] && echo "/ip address add address=$IP/$MASKA interface=bridge"
  echo "/ip address add address=192.168.88.1/24 interface=bridge"
  [ -n "$GW" ] && echo "/ip route add gateway=$GW"
  [ -n "${DNS:-}" ] && echo "/ip dns set servers=$DNS"
  echo "/system identity set name=$NODE"
  echo "/system clock set time-zone-name=Europe/Prague"
  echo "/ip service set www disabled=no"
  echo "/user set admin password=$MT_PASSWORD"
} > "$RSC"
chmod 600 "$RSC"
say "  konfigurace po instalaci: $RSC (jen síť; rádio nastavím potom přes API)"

ip addr add 192.168.88.1/24 dev "$IFACE" 2>/dev/null
say "  spouštím server, krabice musí být v etherbootu (BOOTP)"
"$CACHE/netinstall-cli" -v -s "$RSC" -a 192.168.88.2 \
    ${MNDP_MAC:+--mac "$MNDP_MAC"} \
    "$CACHE/routeros-$VER-$ARCH.npk" "$CACHE/wireless-$VER-$ARCH.npk" 2>&1 \
  | grep -viE '^Received a BOOTP|^Assigned' | tee "$CACHE/netinstall.log"

grep -qi "Successfully finished" "$CACHE/netinstall.log" || {
  shred -u "$RSC" 2>/dev/null || rm -f "$RSC"
  die "Netinstall neproběhl. Zkontroluj, že je krabice v etherbootu (drž reset při zapnutí)."
}
shred -u "$RSC" 2>/dev/null || rm -f "$RSC"

step "Čekám, než krabice naběhne"
CIL="${IP:-192.168.88.1}"
for i in $(seq 1 30); do
  ping -c1 -W1 "$CIL" >/dev/null 2>&1 && { say "  naběhla na $CIL (~$((i*5))s)"; break; }
  sleep 5
done
curl -s -m 15 -u "$AUTH" "http://$CIL/rest/system/resource" | jq -c '{version,"free":."free-hdd-space"}' \
  || die "krabice nabootovala, ale REST neodpovídá na $CIL"

nastav_radio "$CIL"
step "Čekám na spoj (beamforming 1–4 min)"
for i in $(seq 1 24); do
  S=$(curl -s -m 15 -u "$AUTH" -X POST -H 'Content-Type: application/json' -d '{"numbers":"wlan60-1","once":""}' \
      "http://$CIL/rest/interface/w60g/monitor" | jq -r '.[0].connected // "?"' 2>/dev/null)
  [ "$S" = true ] && break
  printf '.'; sleep 10
done
printf '\n'
po_oprave "$CIL"

step "HOTOVO"
say "Nezapomeň: pokud jsi zapínal preboot-etherboot, vypni ho:"
say "  /system routerboard settings set preboot-etherboot=disabled"
