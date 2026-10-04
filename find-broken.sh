#!/usr/bin/env bash
# find-broken.sh — projde rozsah, najde MikroTiky a řekne, kde chybí 60GHz rádio
# a kde je spoj dole.
#
# Použití:  ./find-broken.sh 10.0.0.0/16
#           ./find-broken.sh 10.0.82.0/24 -u admin
#
# Potřebuje: nmap, curl, jq. Sken /16 trvá ~4 minuty.

set -uo pipefail

USER_NAME="admin"
PASSWORD="${MT_PASSWORD:-}"
JOBS=24

usage() { echo "Použití: find-broken.sh <CIDR> [-u uživatel] [-p heslo] [-j paralelně]"; }

[ $# -ge 1 ] || { usage; exit 1; }
CIDR=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--user)     USER_NAME="$2"; shift 2 ;;
    -p|--password) PASSWORD="$2"; shift 2 ;;
    -j|--jobs)     JOBS="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)             CIDR="$1"; shift ;;
  esac
done
[ -n "$CIDR" ] || { usage; exit 1; }

for bin in nmap curl jq; do
  command -v "$bin" >/dev/null || { echo "chybí $bin" >&2; exit 1; }
done

[ -n "$PASSWORD" ] || { read -rsp "heslo pro $USER_NAME: " PASSWORD; echo; }
export USER_NAME PASSWORD

echo ">>> skenuju $CIDR na port 8291 (winbox)"
HOSTS="$(nmap -Pn -n --open -p 8291 --min-rate 600 --host-timeout 20s "$CIDR" -oG - \
         | awk '/8291\/open/{print $2}')"
COUNT="$(printf '%s\n' "$HOSTS" | grep -c . || true)"
echo ">>> nalezeno $COUNT MikroTiků, ptám se jich na stav"
echo

probe() {
  ip="$1"
  a="$USER_NAME:$PASSWORD"
  res="$(curl -sS -m 8 -u "$a" "http://$ip/rest/system/resource" 2>/dev/null)"
  echo "$res" | jq -e . >/dev/null 2>&1 || { printf '%-15s  REST neodpovídá\n' "$ip"; return; }
  ident="$(curl -sS -m 8 -u "$a" "http://$ip/rest/system/identity" 2>/dev/null | jq -r '.name // "?"')"
  board="$(echo "$res" | jq -r '."board-name"')"
  ver="$(echo "$res" | jq -r '.version' | cut -d' ' -f1)"
  wl="$(curl -sS -m 8 -u "$a" "http://$ip/rest/system/package" 2>/dev/null \
        | jq -r '.[] | select(.name=="wireless") | .disabled')"
  w60="$(curl -sS -m 8 -u "$a" "http://$ip/rest/interface/w60g" 2>/dev/null)"
  if echo "$w60" | jq -e 'type=="array"' >/dev/null 2>&1; then
    mon="$(curl -sS -m 10 -u "$a" -X POST -H 'Content-Type: application/json' \
           -d '{"numbers":"wlan60-1","once":""}' "http://$ip/rest/interface/w60g/monitor" 2>/dev/null)"
    conn="$(echo "$mon" | jq -r 'if type=="array" and length>0 then .[0].connected else "?" end')"
    rssi="$(echo "$mon" | jq -r 'if type=="array" and length>0 then (.[0].rssi // "-") else "-" end')"
    case "$conn" in
      true) stav="spoj OK (rssi $rssi)" ;;
      *)    stav="!! SPOJ DOLE" ;;
    esac
  else
    case "$wl" in
      true) stav="!! RADIO CHYBI - balicek wireless je VYPNUTY  -> fix-w60g.sh $ip" ;;
      "")   stav="bez 60GHz radia" ;;
      *)    stav="!! w60g nedostupne" ;;
    esac
  fi
  printf '%-15s  %-22s %-14s %-8s %s\n' "$ip" "$ident" "$board" "$ver" "$stav"
}
export -f probe

printf '%s\n' "$HOSTS" | grep . | xargs -P "$JOBS" -I{} bash -c 'probe "$@"' _ {} | sort

echo
echo ">>> řádky s '!!' stojí za pozornost."
echo ">>> 'balicek wireless je VYPNUTY' = krabice žije, jen nemá ovladač rádia; opravíš ji na dálku."
