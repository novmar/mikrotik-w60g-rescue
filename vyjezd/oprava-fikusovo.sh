#!/usr/bin/env bash
# Oprava uzlu fikusovo — Fikusová — PŘÍSTUPOVÝ BOD spoje na jab2fikusovo
# Kabel z notebooku do krabice a spustit pod rootem.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec ./oprava-na-miste.sh nodes/fikusovo.conf "$@"
