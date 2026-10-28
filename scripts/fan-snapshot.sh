#!/bin/sh
# fan-snapshot.sh — read-only one-shot view of the DGX Spark fan/thermal state.
# Run on the Spark itself, or over ssh:  ssh <host> 'sh -s' < fan-snapshot.sh
#
# Prints: requested state, hottest thermal zone, both fan RPMs, GPU temperature/clock/power.
# Nothing is written; safe to run from cron.
set -u

CTL=${CTL:-/usr/local/sbin/dgx-fan-control}

state="na"
if [ -x "$CTL" ]; then
  state=$(timeout 10 "$CTL" status 2>/dev/null | sed -n 's/^state=\([0-9]*\)\/.*/\1/p' | head -1)
  hottest=$(timeout 10 "$CTL" status 2>/dev/null | sed -n 's/.*hottest=\([0-9.]*\)C.*/\1/p' | head -1)
else
  hottest=""
fi

if [ -z "${hottest:-}" ]; then
  # fall back to the raw thermal zones (millidegrees)
  hottest=$(for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] && echo $(( $(cat "$z" 2>/dev/null || echo 0) / 1000 ))
  done | sort -rn | head -1)
fi

fan1="na"; fan2="na"
for d in /sys/class/hwmon/hwmon*; do
  [ -r "$d/fan1_input" ] || continue
  # prefer the EC cooling device if the kernel exposes its type
  [ -r "$d/name" ] && grep -qi "dgx\|ec_fan" "$d/name" 2>/dev/null || true
  fan1=$(cat "$d/fan1_input" 2>/dev/null || echo na)
  fan2=$(cat "$d/fan2_input" 2>/dev/null || echo na)
  break
done

gpu="na"
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu=$(nvidia-smi --query-gpu=temperature.gpu,clocks.sm,power.draw \
        --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
fi

printf 'state=%s/12 hottest=%sC fan1=%sRPM fan2=%sRPM gpu(T,clock,power)=%s\n' \
  "${state:-na}" "${hottest:-na}" "$fan1" "$fan2" "$gpu"

# A state of 0 while a temperature is well above idle is the failure worth alarming on:
# on our units that coincided with 0 RPM and the SoC clamping the GPU to 611 MHz.
if [ "${state:-na}" = "0" ] && [ "${hottest:-0}" -ge 60 ] 2>/dev/null; then
  echo "WARN: fan state 0 with hottest zone ${hottest}C — check RPM and the daemon" >&2
  exit 2
fi
