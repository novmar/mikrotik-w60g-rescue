#!/usr/bin/env bash
# fix-w60g.sh — oprava MikroTik 60GHz pojítka, kterému po upgradu RouterOS 6 → 7
# zmizelo rádio, protože chybí (nebo je vypnutý) balíček `wireless`.
#
# Použití:   ./fix-w60g.sh 10.0.0.2
#            ./fix-w60g.sh 10.0.0.2 --probe          # jen diagnostika, nic nemění
#            MT_PASSWORD='...' ./fix-w60g.sh 10.0.0.2 --yes
#
# Skript si sám zjistí verzi RouterOS a architekturu, stáhne odpovídající NPK,
# dostane ho na krabici a rebootuje. Potřebuje: bash, curl, jq.
#
# Pozadí, zdroje a postup pro případ, kdy tohle nestačí: README.md

set -uo pipefail

# ---------------------------------------------------------------- nastavení --
USER_NAME="admin"
PASSWORD="${MT_PASSWORD:-}"
PROBE_ONLY=0
ASSUME_YES=0
FORCE=0
NPK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/npk"
MIRROR="https://download.mikrotik.com/routeros"
# Přidání NOVÉHO balíčku potřebuje ve flash jeho plnou velikost plus rezervu.
# (Upgrade existujícího balíčku naproti tomu přepisuje starou instalaci a vystačí
# si skoro s ničím — proto projde 12MB routeros tam, kde 1,8MB wireless ne.)
MARGIN=350000
BOOT_WAIT=240      # s, jak dlouho čekat na návrat po rebootu
LINK_WAIT=300      # s, jak dlouho čekat na navázání spoje

usage() {
  cat <<'EOF'
Použití: fix-w60g.sh <IP> [volby]

  -u, --user <jméno>     uživatel (výchozí admin)
  -p, --password <heslo> heslo; jde dát i přes proměnnou MT_PASSWORD
      --probe            jen zjisti stav, nic neměň
      --yes              neptej se na potvrzení
      --force            zkus instalaci i při nedostatku místa na flash
  -h, --help             tahle nápověda

Heslo se nikam neukládá. Když ho nezadáš, skript se na něj zeptá.

Návratové kódy: 0 = v pořádku / opraveno, 1 = chyba, 2 = na dálku to nejde
EOF
}

# ------------------------------------------------------------------ parsing --
[ $# -ge 1 ] || { usage; exit 1; }
IP=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user)     USER_NAME="$2"; shift 2 ;;
    -p|--password) PASSWORD="$2"; shift 2 ;;
    --probe)       PROBE_ONLY=1; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    --force)       FORCE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            echo "neznámá volba: $1" >&2; exit 1 ;;
    *)             IP="$1"; shift ;;
  esac
done
[ -n "$IP" ] || { usage; exit 1; }

for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "chybí $bin" >&2; exit 1; }
done

if [ -z "$PASSWORD" ]; then
  read -rsp "heslo pro $USER_NAME@$IP: " PASSWORD; echo
fi

API="http://$IP/rest"
AUTH="$USER_NAME:$PASSWORD"

say()  { printf '%s\n' "$*"; }
step() { printf '\n>>> %s\n' "$*"; }
die()  { printf 'CHYBA: %s\n' "$*" >&2; exit 1; }

get()  { curl -sS -m 15 -u "$AUTH" "$API$1"; }
post() {
  local path="$1" data="${2-}" to="${3-60}"
  [ -n "$data" ] || data='{}'
  curl -sS -m "$to" -u "$AUTH" -X POST -H 'Content-Type: application/json' -d "$data" "$API$path"
}
patch(){ curl -sS -m 15 -u "$AUTH" -X PATCH -H 'Content-Type: application/json' -d "$2" "$API$1"; }

human() { awk -v b="$1" 'BEGIN{printf "%.2f MB", b/1048576}'; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  read -rp "$1 [a/N] " a
  case "$a" in a|A|y|Y) return 0 ;; *) return 1 ;; esac
}

wait_for_box() {
  local waited=0
  printf 'čekám na návrat'
  sleep 25
  while [ "$waited" -lt "$BOOT_WAIT" ]; do
    if get /system/resource >/dev/null 2>&1; then printf ' — zpátky po ~%ss\n' "$((waited + 25))"; return 0; fi
    printf '.'; sleep 5; waited=$((waited + 5))
  done
  printf '\n'; return 1
}

reboot_box() {
  post /system/reboot >/dev/null 2>&1 || true
  wait_for_box || die "krabice se po rebootu nevrátila do ${BOOT_WAIT}s — tohle už je na výjezd"
}

# stáhne balíček krabicí (má-li ven), jinak ho nahraje odtud přes FTP
# POZOR: soubor musí skončit v KOŘENI, ne v adresáři flash/ — instalátor
# hledá .npk jen tam. Na krabicích s >64 MB RAM je kořen RAM disk, takže
# staging balíčku nestojí ani bajt flash.
deliver_npk() {
  local url="$1" name="$2" fetch
  fetch="$(post /tool/fetch "{\"url\":\"$url\",\"check-certificate\":\"no\",\"mode\":\"https\"}" 180 2>/dev/null || true)"
  if echo "$fetch" | jq -e 'if type=="array" then (.[-1].status=="finished") else false end' >/dev/null 2>&1; then
    say "  $name — stáhla si ho krabice sama"
    return 0
  fi
  say "  $name — krabice nemá ven, nahraju ho odtud přes FTP"
  mkdir -p "$NPK_DIR"
  [ -f "$NPK_DIR/$name" ] || curl -sS -m 300 -o "$NPK_DIR/$name" "$url" || die "stažení $name selhalo"
  local ftp_id ftp_was rc=1
  ftp_id="$(get /ip/service | jq -r '.[] | select(.name=="ftp") | .".id"')"
  ftp_was="$(get /ip/service | jq -r '.[] | select(.name=="ftp") | .disabled')"
  [ "$ftp_was" = "true" ] && patch "/ip/service/$ftp_id" '{"disabled":"false"}' >/dev/null
  curl -sS -m 600 --ftp-pasv -T "$NPK_DIR/$name" "ftp://$IP/" --user "$AUTH" >/dev/null && rc=0
  [ "$ftp_was" = "true" ] && patch "/ip/service/$ftp_id" '{"disabled":"true"}' >/dev/null
  return $rc
}

# ------------------------------------------------------------- 1. inventura --
step "Zjišťuji stav $IP"
RES="$(get /system/resource)" || die "REST API neodpovídá (je zapnutá služba www? sedí heslo?)"
echo "$RES" | jq -e . >/dev/null 2>&1 || die "odpověď není JSON — tohle nevypadá na RouterOS s REST API"

IDENT="$(get /system/identity | jq -r '.name // "?"')"
VER_FULL="$(echo "$RES" | jq -r '.version')"
VER="${VER_FULL%% *}"
ARCH="$(echo "$RES" | jq -r '."architecture-name"')"
BOARD="$(echo "$RES" | jq -r '."board-name"')"
FREE="$(echo "$RES" | jq -r '."free-hdd-space"')"
TOTAL="$(echo "$RES" | jq -r '."total-hdd-space"')"
UPTIME="$(echo "$RES" | jq -r '.uptime')"

say "  identita   : $IDENT"
say "  deska      : $BOARD ($ARCH)"
say "  RouterOS   : $VER_FULL, uptime $UPTIME"
say "  flash      : volno $(human "$FREE") z $(human "$TOTAL")"

PKGS="$(get /system/package)"
# Pozor na dvojí význam disabled=true:
#   - s vyplněnou version/build-time = balíček NA KRABICI JE, jen je vypnutý
#   - bez nich (příznak A = available) = je to jen nabídka ze serveru, na krabici není
WL_ROW="$(echo "$PKGS" | jq -c '.[] | select(.name=="wireless")')"
WL_DISABLED="$(echo "$WL_ROW" | jq -r '.disabled // empty')"
WL_VERSION="$(echo "$WL_ROW" | jq -r '.version // empty')"
WL_SIZE="$(echo "$WL_ROW" | jq -r '.size // 0')"
[ -n "$WL_SIZE" ] || WL_SIZE=0

if [ -z "$WL_ROW" ]; then
  WL_STATE="missing";   say "  wireless   : CHYBÍ ÚPLNĚ  <-- tohle je ta závada"
elif [ -z "$WL_VERSION" ]; then
  WL_STATE="available"; say "  wireless   : v seznamu jen jako dostupný na serveru (příznak A), na krabici NENÍ"
  WL_SIZE=0
elif [ "$WL_DISABLED" = "true" ]; then
  WL_STATE="disabled";  say "  wireless   : NAINSTALOVANÝ ($WL_VERSION), ale VYPNUTÝ  <-- tohle je ta závada"
else
  WL_STATE="ok";        say "  wireless   : nainstalovaný a zapnutý ($WL_VERSION)"
fi

W60G="$(get /interface/w60g)"
if echo "$W60G" | jq -e 'type=="array"' >/dev/null 2>&1; then
  HAS_RADIO=1
  say "  rádio      : $(echo "$W60G" | jq -r '.[] | "\(.name) mode=\(.mode) ssid=\(.ssid) running=\(.running)"')"
else
  HAS_RADIO=0
  say "  rádio      : /interface w60g NEEXISTUJE (ovladač chybí)"
fi

link_status() {
  post /interface/w60g/monitor '{"numbers":"wlan60-1","once":""}' 20 2>/dev/null \
    | jq -r 'if type=="array" and length>0 then .[0] |
        "connected=\(.connected) rssi=\(.rssi // "-") tx-mcs=\(."tx-mcs" // "-") phy=\(."tx-phy-rate" // "-")"
      else "nedostupné" end' 2>/dev/null || echo "nedostupné"
}

[ "$HAS_RADIO" = 1 ] && say "  spoj       : $(link_status)"

# ------------------------------------------------------------ 2. rozhodnutí --
if [ "$HAS_RADIO" = 1 ] && [ "$WL_STATE" = "ok" ]; then
  step "Rádio je na svém místě — tahle krabice tuhle závadu nemá."
  say "Pokud spoj přesto nejede, problém je jinde: protějšek, zaměření, napájení."
  exit 0
fi

[ "$PROBE_ONLY" = 1 ] && { step "--probe: končím bez zásahu."; exit 0; }

# ------------------------------------------------------- 3. sehnání balíčku --
NPK="wireless-$VER-$ARCH.npk"
URL="$MIRROR/$VER/$NPK"
step "Potřebný balíček: $NPK (verze MUSÍ sedět s běžícím RouterOS)"

NPK_SIZE="$(curl -sSI -m 20 "$URL" | awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}')"
if [ -z "${NPK_SIZE:-}" ]; then
  if [ -f "$NPK_DIR/$NPK" ]; then
    NPK_SIZE="$(stat -c %s "$NPK_DIR/$NPK")"
    say "  mikrotik.com nedostupný, použiju přibalenou kopii z npk/"
  else
    die "balíček $NPK se nepodařilo najít ani na $MIRROR, ani v npk/"
  fi
else
  say "  $URL ($(human "$NPK_SIZE"))"
fi

FREE_AFTER=$((FREE + WL_SIZE))      # po případné odinstalaci vypnutého balíčku
NEED=$((NPK_SIZE + MARGIN))
say "  k dispozici bude ~$(human "$FREE_AFTER"), instalace potřebuje ~$(human "$NEED")"

# -------------------------------------- 3b. málo místa → společná instalace --
if [ "$FREE_AFTER" -lt "$NEED" ] && [ "$FORCE" = 0 ]; then
  step "Málo místa na flash — samostatná instalace balíčku tady neprojde"
  say "Zkusím obejít: upgrade celého systému, při kterém se wireless nainstaluje"
  say "společně s routeros. Instalátor přepisuje starou instalaci, takže se vejde."

  post /system/package/update/check-for-updates >/dev/null 2>&1
  sleep 3
  UPD="$(get /system/package/update)"
  LATEST="$(echo "$UPD" | jq -r '."latest-version" // empty')"
  say "  kanál: $(echo "$UPD" | jq -r '.channel'), nainstalováno $VER, k dispozici ${LATEST:-?}"

  if [ -z "$LATEST" ] || [ "$LATEST" = "$VER" ]; then
    say "  novější verze není, zkusím opačný směr: STARŠÍ dvojici, která se vejde"

    # Kolik flash spolkne něco jiného než balíčky (konfigurace, zbytky po
    # migraci z v6, rezerva). Krabice upgradovaná z šestky jich mívá o 1+ MB víc
    # než čerstvě Netinstallovaná — a přesně o to místo tu jde.
    ROS_SIZE="$(echo "$PKGS" | jq -r '.[] | select(.name=="routeros") | .size // 0')"
    OVERHEAD=$((TOTAL - FREE - ROS_SIZE - WL_SIZE))
    say "  mimo balíčky zabírá flash $(human "$OVERHEAD") (konfigurace, zbytky po migraci)"

    PICK=""
    for CAND in 7.22.1 7.19.4 7.16 7.13.5; do
      R="$(curl -sSI -m 15 "$MIRROR/$CAND/routeros-$CAND-$ARCH.npk" | awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}')"
      W="$(curl -sSI -m 15 "$MIRROR/$CAND/wireless-$CAND-$ARCH.npk"  | awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}')"
      [ -n "${R:-}" ] && [ -n "${W:-}" ] || continue
      # nainstalovaná velikost vychází zhruba na 1,05násobek NPK
      EST=$(( (R + W) * 105 / 100 + OVERHEAD + MARGIN ))
      if [ "$EST" -le "$TOTAL" ]; then
        say "  $CAND: routeros $(human "$R") + wireless $(human "$W") → odhad $(human "$EST") z $(human "$TOTAL")  VEJDE SE"
        PICK="$CAND"; break
      fi
      say "  $CAND: odhad $(human "$EST") z $(human "$TOTAL")  nevejde"
    done

    if [ -z "$PICK" ]; then
      cat <<EOF

Ani starší dvojice se do flash nevejde. Tohle už přes síť nespravíš — zbývá
Netinstall na místě (formátuje flash, takže zbytky po migraci zmizí a vejde
se i aktuální verze). Postup je v README, oddíl "Když to přes síť nejde".

Spuštění s --force instalaci přesto zkusí (nic nerozbije, jen selže).
EOF
      exit 2
    fi

    say ""
    say "Plán: nainstalovat routeros $PICK + wireless $PICK NAJEDNOU (downgrade)."
    say "      Rádio se vrátí i s konfigurací; krabice zůstane na starší verzi."
    confirm "Pokračovat?" || { say "nic jsem neudělal"; exit 0; }

    deliver_npk "$MIRROR/$PICK/routeros-$PICK-$ARCH.npk" "routeros-$PICK-$ARCH.npk" \
      || die "routeros balíček se nepodařilo dopravit"
    deliver_npk "$MIRROR/$PICK/wireless-$PICK-$ARCH.npk" "wireless-$PICK-$ARCH.npk" \
      || die "wireless balíček se nepodařilo dopravit"
    say "  v kořeni leží:"
    get /file | jq -r '.[] | select(.type=="package") | "    \(.name) \(.size)"'

    step "Spouštím downgrade — nainstaluje se obojí najednou"
    post /system/package/downgrade >/dev/null 2>&1 || true
    wait_for_box || die "krabice se po downgradu nevrátila — tohle už je na výjezd"
  else
    say ""
    say "Plán: stáhnout routeros-$LATEST-$ARCH.npk i wireless-$LATEST-$ARCH.npk"
    say "      do kořene a jedním rebootem nainstalovat obojí."
    confirm "Pokračovat?" || { say "nic jsem neudělal"; exit 0; }

    deliver_npk "$MIRROR/$LATEST/routeros-$LATEST-$ARCH.npk" "routeros-$LATEST-$ARCH.npk" \
      || die "routeros balíček se nepodařilo dopravit"
    deliver_npk "$MIRROR/$LATEST/wireless-$LATEST-$ARCH.npk" "wireless-$LATEST-$ARCH.npk" \
      || die "wireless balíček se nepodařilo dopravit"

    say "  v kořeni leží:"
    get /file | jq -r '.[] | select(.type=="package") | "    \(.name) \(.size)"'

    step "Reboot — nainstaluje se obojí najednou"
    reboot_box
  fi
else
  if [ "$WL_STATE" = "disabled" ]; then
    say ""
    say "Plán: odinstalovat poškozený balíček → reboot → nahrát čistý → reboot."
    say "('enable' nestačí: po rebootu se balíček vrátí do disabled a log mlčí)"
  else
    say ""
    say "Plán: nahrát balíček → reboot."
  fi
  confirm "Pokračovat?" || { say "nic jsem neudělal"; exit 0; }

  if [ "$WL_STATE" = "disabled" ]; then
    step "Odinstaluju poškozený balíček"
    post /system/package/uninstall '{"numbers":"wireless"}' >/dev/null
    reboot_box
    FREE="$(get /system/resource | jq -r '."free-hdd-space"')"
    say "  volno po odinstalaci: $(human "$FREE")"
  fi

  step "Dopravuji $NPK na krabici"
  deliver_npk "$URL" "$NPK" || die "balíček se nepodařilo dostat na krabici"
  ON_BOX="$(get /file | jq -r --arg n "$NPK" '.[] | select(.name==$n) | .size // empty')"
  [ -n "$ON_BOX" ] || die "balíček na krabici po přenosu není"
  say "  na krabici leží $NPK ($(human "$ON_BOX"))"

  step "Reboot — při startu se balíček nainstaluje"
  reboot_box
fi

# ------------------------------------------------------------- 4. kontrola --
step "Kontrola"
PKGS="$(get /system/package)"
WL_NOW="$(echo "$PKGS" | jq -r '.[] | select(.name=="wireless" and (.version // "") != "") | "\(.version) disabled=\(.disabled)"')"
if [ -z "$WL_NOW" ]; then
  LOG="$(get /log | jq -r '.[] | "\(.time) \(.message)"' | grep -iE 'upgrade failed|disk space|installed' | tail -3)"
  say "  balíček se NENAINSTALOVAL"
  [ -n "$LOG" ] && say "  log říká: $LOG"
  say ""
  say "  Když log hlásí 'upgrade failed, free NNN kB of disk space', je flash plná"
  say "  a na dálku se to spravit nedá — README, oddíl 'Když to přes síť nejde'."
  exit 2
fi
say "  wireless: $WL_NOW"

W60G="$(get /interface/w60g)"
if ! echo "$W60G" | jq -e 'type=="array"' >/dev/null 2>&1; then
  die "balíček je nainstalovaný, ale /interface w60g pořád není — tohle je nad rámec skriptu"
fi
say "  rádio: $(echo "$W60G" | jq -r '.[] | "\(.name) mode=\(.mode) ssid=\(.ssid) running=\(.running)"')"
say "  bridge porty: $(get /interface/bridge/port | jq -r '[.[].interface] | join(", ")')"

step "Čekám na navázání spoje (beamforming trvá 1–4 minuty)"
waited=0
while [ "$waited" -lt "$LINK_WAIT" ]; do
  ST="$(link_status)"
  case "$ST" in
    connected=true*) say "  $ST"; step "HOTOVO — spoj je nahoře."; exit 0 ;;
  esac
  printf '.'; sleep 10; waited=$((waited + 10))
done

printf '\n'
say "  poslední stav: $(link_status)"
step "Rádio je zpátky, ale spoj se zatím nechytil."
say "Zkontroluj protějšek: musí sedět ssid, mode (jedna strana bridge/ap-bridge,"
say "druhá station-bridge) a hlavně musí druhá strana vůbec žít."
exit 0
