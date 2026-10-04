#!/usr/bin/env bash
# Oprava uzlu streltojab355 — Střelničná — stanice spoje na jab355tostrel
# Kabel z notebooku do krabice a spustit pod rootem.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec ./oprava-na-miste.sh nodes/strel.conf "$@"
