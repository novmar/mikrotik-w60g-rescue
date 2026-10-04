#!/usr/bin/env bash
# priprav.sh — spusť DOMA, dokud máš síť. Stáhne všechno potřebné a vytáhne
# z živého protějšku parametry rádia, aby je skript na místě nemusel hádat.
#
#   ./priprav.sh                      # připraví všechny uzly
#   ./priprav.sh nodes/uskol.conf     # jen jeden
#
# Hesla rádií se ukládají do <profil>.secrets (chmod 600) a jsou v .gitignore.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR="https://download.mikrotik.com/routeros"
VER="${VER:-7.24.5}"
NI_VER="7.16"
CACHE="${TMPDIR:-/tmp}/w60g-vyjezd"

say() { printf '%s\n' "$*"; }
step(){ printf '\n>>> %s\n' "$*"; }

for b in curl jq; do command -v "$b" >/dev/null || { echo "chybí $b" >&2; exit 1; }; done

MT_USER="${MT_USER:-admin}"
[ -n "${MT_PASSWORD:-}" ] || { read -rsp "heslo admina: " MT_PASSWORD; echo; }
AUTH="$MT_USER:$MT_PASSWORD"

PROFILY=("$@")
[ ${#PROFILY[@]} -gt 0 ] || PROFILY=("$HERE"/nodes/*.conf)

step "Stahuji balíčky a netinstall do $CACHE (ať to na místě nepotřebuje internet)"
mkdir -p "$CACHE"; cd "$CACHE" || exit 1
for a in arm arm64; do
  for f in "routeros-$VER-$a.npk" "wireless-$VER-$a.npk"; do
    if [ -s "$f" ]; then say "  $f už mám"
    else say "  $f"; curl -sS -m 900 -O "$MIRROR/$VER/$f" || say "    !! nestáhlo se"; fi
  done
done
if [ -x "$CACHE/netinstall-cli" ]; then say "  netinstall-cli už mám"
else
  say "  netinstall-$NI_VER.tar.gz"
  curl -sS -m 900 -O "$MIRROR/$NI_VER/netinstall-$NI_VER.tar.gz" && tar xzf "netinstall-$NI_VER.tar.gz"
fi

for P in "${PROFILY[@]}"; do
  [ -f "$P" ] || continue
  # shellcheck disable=SC1090
  ( . "$P"
    step "$NODE  (protějšek $PEER_NAME $PEER_IP)"
    if ! curl -s -m 8 -u "$AUTH" "http://$PEER_IP/rest/system/identity" >/dev/null 2>&1; then
      say "  protějšek neodpovídá — parametry rádia si na místě vyžádá skript ručně"
      exit 0
    fi
    W="$(curl -s -m 10 -u "$AUTH" "http://$PEER_IP/rest/interface/w60g")"
    ssid="$(echo "$W" | jq -r '.[0].ssid')"
    pass="$(echo "$W" | jq -r '.[0].password // ""')"
    reg="$(echo  "$W" | jq -r '.[0].region')"
    pmode="$(echo "$W" | jq -r '.[0].mode')"
    rmac="$(curl -s -m 10 -u "$AUTH" "http://$PEER_IP/rest/interface/w60g/station" | jq -r '.[0]."remote-address" // ""')"
    [ "$reg" = "no-region-set" ] && reg="eu"
    case "$pmode" in
      bridge|ap-bridge) mode="station-bridge"; putin="" ;;
      *)                mode="bridge";        putin="bridge" ;;
    esac
    umask 077
    cat > "$P.secrets" <<EOF
# vygeneroval priprav.sh $(date '+%Y-%m-%d %H:%M') z protějšku $PEER_IP
# OBSAHUJE HESLO RÁDIA — nedávej do gitu
SSID="$ssid"
WPASS="$pass"
REGION="$reg"
MODE="$mode"
PUT_IN="$putin"
RADIO_MAC="$rmac"
EOF
    say "  ssid=$ssid  mode=$mode  region=$reg  rádio protějšku vidí $rmac"
    say "  zapsáno do $(basename "$P").secrets"
  )
done

step "Hotovo"
say "Vezmi s sebou: notebook, ethernetový kabel, tenhle adresář a $CACHE"
say "Na místě:  sudo ./oprava-na-miste.sh nodes/<uzel>.conf"
