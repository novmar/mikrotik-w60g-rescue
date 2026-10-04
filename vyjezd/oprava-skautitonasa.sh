#!/usr/bin/env bash
# Oprava uzlu skautitonasa — Na Samotě 2 — stanice spoje na nasatoskauti
# Kabel z notebooku do krabice a spustit pod rootem.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
exec ./oprava-na-miste.sh nodes/skautitonasa.conf "$@"
