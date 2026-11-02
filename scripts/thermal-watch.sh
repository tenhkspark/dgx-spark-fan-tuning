#!/bin/bash
# thermal-watch.sh — alarm on DGX Spark fan/thermal trouble. Run from cron or any host
# that can ssh to the nodes.
#
#   NODES="node1 node2 user@node3" \
#   ALERT_FILE=/var/log/spark-thermal-alerts.log \
#   ./thermal-watch.sh
#
# Alarm conditions
#   1. the fan-floor daemon is not `active`          (silent death, see README)
#   2. hottest ACPI thermal zone >= ACPI_LIMIT  (default 78 °C)
#   3. GPU temperature        >= GPU_LIMIT      (default 75 °C)
#   4. current fan state == 0                   (0 RPM / EC control lost)
#      — only if the controller cannot be read do we fall back to the
#        `baseline fan1=` value from dmesg, which is 0 on some units while the
#        fans are running fine and therefore false-alarms.
#
# Exit code is always 0: this is a watchdog, not a gate. Alerts go to ALERT_FILE,
# one line per (node, 30 min) so a persistent problem does not flood the log.
set -u

NODES=${NODES:-}
ALERT_FILE=${ALERT_FILE:-/var/log/spark-thermal-alerts.log}
STATE_FILE=${STATE_FILE:-/tmp/spark-thermal-watch.state}
ACPI_LIMIT=${ACPI_LIMIT:-78}
GPU_LIMIT=${GPU_LIMIT:-75}
COOLDOWN=${COOLDOWN:-1800}
CTL=${CTL:-/usr/local/sbin/dgx-fan-control}
UNIT=${UNIT:-dgx-fan-daemon}
SSH_OPTS=${SSH_OPTS:-"-o BatchMode=yes -o ConnectTimeout=5"}

[ -n "$NODES" ] || { echo "set NODES=\"host1 host2 ...\" (ssh targets)" >&2; exit 0; }

NOW=$(date +%s)
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null && touch "$STATE_FILE" 2>/dev/null
mkdir -p "$(dirname "$ALERT_FILE")" 2>/dev/null

for node in $NODES; do
  out=$(ssh $SSH_OPTS "$node" "
    g=\$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
    a=\$(for z in /sys/class/thermal/thermal_zone*/temp; do [ -r \"\$z\" ] && echo \$(( \$(cat \$z 2>/dev/null || echo 0) / 1000 )); done | sort -rn | head -1)
    b=\$(sudo -n dmesg 2>/dev/null | grep -o 'baseline fan1=[0-9]*' | tail -1 | cut -d= -f2)
    s=\$(timeout 10 sudo -n $CTL status 2>/dev/null | sed -n 's/^state=\([0-9]*\)\/.*/\1/p')
    u=\$(systemctl is-active $UNIT 2>/dev/null | head -1)
    echo \"gpu=\${g:-NA} acpi=\${a:-NA} fanbase=\${b:-NA} fanstate=\${s:-NA} unit=\${u:-NA}\"
  " 2>/dev/null)
  [ -n "$out" ] || continue

  gpu=$(printf '%s' "$out" | sed -n 's/.*gpu=\([0-9NA]*\).*/\1/p')
  acpi=$(printf '%s' "$out" | sed -n 's/.*acpi=\([0-9NA]*\).*/\1/p')
  fb=$(printf '%s' "$out" | sed -n 's/.*fanbase=\([0-9NA]*\).*/\1/p')
  fs=$(printf '%s' "$out" | sed -n 's/.*fanstate=\([0-9NA]*\).*/\1/p')
  un=$(printf '%s' "$out" | sed -n 's/.*unit=\([a-z-]*\).*/\1/p')

  reason=""
  # A dead daemon leaves the EC at a low floor, not at 0 RPM, so the temperature
  # and fan-state thresholds can all be satisfied while control is gone.
  case "$un" in
    active) : ;;
    *) reason="fan daemon not active (${un:-NA})" ;;
  esac
  case "$acpi" in ''|*[!0-9]*) : ;; *) [ "$acpi" -ge "$ACPI_LIMIT" ] && reason="${reason:+$reason / }ACPI ${acpi}C" ;; esac
  case "$gpu"  in ''|*[!0-9]*) : ;; *) [ "$gpu"  -ge "$GPU_LIMIT"  ] && reason="${reason:+$reason / }GPU ${gpu}C" ;; esac
  case "$fs" in
    ''|*[!0-9]*)
      # controller unreadable: only then trust the dmesg baseline
      case "$fb" in ''|*[!0-9]*) : ;; *) [ "$fb" -eq 0 ] && reason="${reason:+$reason / }fan controller down + baseline 0" ;; esac ;;
    *)
      [ "$fs" -eq 0 ] && reason="${reason:+$reason / }fan state 0" ;;
  esac

  [ -n "$reason" ] || continue

  last=$(grep "^$node " "$STATE_FILE" 2>/dev/null | awk '{print $2}' | tail -1)
  if [ -n "$last" ] && [ $((NOW - last)) -lt "$COOLDOWN" ]; then continue; fi
  echo "$node $NOW" >> "$STATE_FILE"
  printf '[%s] THERMAL %s: %s (gpu=%s acpi=%s fanbase=%s fanstate=%s unit=%s)\n' \
    "$(date '+%F %T')" "$node" "$reason" "$gpu" "$acpi" "$fb" "$fs" "${un:-NA}" >> "$ALERT_FILE"
done

# drop cooldown entries older than a day
awk -v now="$NOW" '$2 > now-86400' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
  && mv "$STATE_FILE.tmp" "$STATE_FILE"
exit 0
