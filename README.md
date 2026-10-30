[English](README.md) | [한국어](README-ko.md) | [简体中文](README-zh.md) | [日本語](README-ja.md)

<sub>The detailed pages under `docs/` are in English; this README and its translations carry the same numbers.</sub>

> **Where the rest lives:** this repository keeps the GPL-2.0 patch and the fan
> measurements. The cluster's other settings — clock floor, serving, routing, patching,
> watchdogs and the current benchmark results — are in
> [`dgx-spark-tuning`](https://github.com/tenhkspark/dgx-spark-tuning).


# Fan curve notes for a 4-node DGX Spark cluster

What a four-node DGX Spark (GB10) cluster actually did with its fans, the curve we
settled on, and the firmware trap that quietly turns the fans off. The serving recipe we
run (`christopherowen/spark-ds41f`) does not ship fan settings — fan control is a separate
project upstream (`christopherowen/dgx-spark-fan-control`) — so these numbers live here.

This repository is **one patch plus notes**, not a fork:

- `patch/0001-performance-curve.patch` — replaces `PERFORMANCE_CURVE` in the upstream
  userland controller. Nothing else is touched; apply it to your own checkout.
- `docs/` — the curve, the measurements behind it, and the firmware versions to avoid.
- `scripts/` — a read-only snapshot and a thermal watchdog you can drop on any host.
- `deploy/` — the module-autoload file and the systemd unit (with the alias the upstream
  benchmark harness expects).

```
NVIDIA firmware (EC)  ──►  dgx_ec_fan_control kernel module
                                  │  cooling device: additive "fan floor" state 0..12
                                  ▼
                       dgx-fan-control daemon  (userland, upstream + this patch)
                                  │  every 2s: filtered hottest zone ──► state
                                  ▼
                     fans: state 1 ≈ 2,700 RPM … state 12 = 9,000 / 13,500 RPM
```

## The failure mode worth knowing first

On our four units, loading the kernel module **without running the daemon** left both
fans at **0 RPM**. The SoC thermal zone then reached **96 °C**, and the platform clamped
the GPU to **611 MHz** — with `nvidia-smi` still reporting 96% utilisation and 8–11 W, and
no `HW Thermal Slowdown` flag, because the limit comes from the SoC side, not the GPU die.
Two nodes in that state made the whole cluster two to three times slower (prose 34 → 65
tok/s, prefill 2.6K → 6.3K tok/s, structured output 86 → 165 tok/s).

Recovery needs a **power cable pull for 30 seconds** (EC reset). A reboot does not clear
it. Upstream documents "leave the service stopped to keep NVIDIA's curve"; that is not
what we observed, so treat the fan RPM as something you verify, not assume.

Two consequences we build on:

1. Keep the daemon running (`Restart=always` semantics, see `deploy/`), and
2. make the curve unable to ask for less than state 1, so a stopped or wedged daemon
   cannot leave a 0-RPM request in place (the patch's `(0.0, 1)` entry).

## The curve we run

Upstream requests `(50°C, 3) (55, 5) (60, 8) (65, 10) (70, 12)`. Below 50 °C it asks for
state 0. Our patch asks for less cooling until ~62 °C, and never less than state 1:

| Filtered hottest zone | This curve | State | Common floor |
|---|---|---|---|
| < 52 °C | (0.0, 1) | 1 | 2,700 RPM |
| 52 °C | (52.0, 2) | 2 | 3,600 |
| 57 °C | (57.0, 3) | 3 | 4,500 |
| 62 °C | (62.0, 4) | 4 | 5,400 |
| 66 °C | (66.0, 5) | 5 | 6,300 |
| 70 °C | (70.0, 6) | 6 | 7,200 |
| 73 °C | (73.0, 8) | 8 | 9,000 |
| 76 °C | (76.0, 10) | 10 | 11,250 |
| 78 °C and above | (78.0, 12) | 12 | 9,000 / 13,500 |

Everything above 78 °C is the upstream maximum, deliberately: our alarm lines are ACPI
78 °C / GPU 75 °C, so the last five degrees are full speed on purpose. Smoothing and
rate limits stay as upstream: `alpha=0.35`, up to +2 states per 2 s sample, −1 state per
sample, 4 °C hysteresis on the way down, state 12 on transport failure.

Read the state as a *request*: the firmware takes the maximum of its own demand and this
one, so the measured RPM is an upper envelope, not the table value.

## What it changed, measured

Load harness: two parallel 700-token generations per node, six waves, all four nodes
serving, same prompts before and after.

| Configuration | Idle | Mid load | Speed |
|---|---|---|---|
| Daemon stopped (module only) | 0 RPM, SoC 96 °C, GPU clamped 611 MHz | — | 2–3× slower than below |
| Upstream curve | state 10–12, 10,935–13,500 RPM | — | baseline |
| This curve, first step (+5 °C shift) | state 3, 4,500–5,670 RPM | ACPI 63–69 °C, state 3–5, 4,450–6,300 RPM | unchanged |
| This curve, current (+7 °C shift, floor 1) | state 2, 3,600–4,185 RPM, ACPI 50–53 °C | ACPI 65–73 °C, state 5–6, 5,400–7,200 RPM | unchanged (700 tok 10.7–10.9 s, 400 tok 5.6 s) |

The honest trade-off: idle RPM dropped by about 20% (4,500 → 3,600), mid-load
temperatures rose by roughly 4 °C and the state went up one step. Same work, same silicon,
so the equilibrium just moved along "hotter but slower fans". **Under real load the noise
is close to unchanged** — to actually quiet a Spark, fix the placement (separate room,
cupboard, intake/exhaust clearance) rather than the curve.

## Firmware: do not take the October 2026 set

Fan control depends on firmware paths that the October set removed. What we measured on
the September set versus what NVIDIA offered:

| Component | September 2026 (works) | October 2026 (breaks fan control) |
|---|---|---|
| EC | 3.5.8 (`0x03000508`) | 3.13.7 (`0x03000d07`) |
| SoC | 2.155.11 (`0x02009b0b`) | 2.158.15 (`0x02009e0f`) |
| USB-C PD | 5.22 (`0x00000516`) | 5.25 (`0x00000519`) |

Observed on the October set: floor writes (cmd 3/5) rejected with `0xff`, reads returning
`0xffff`, the override code removed, and the fan range clamped to 975–4,350 RPM instead of
1,260–9,000 / 1,890–13,500. Mixing the new SoC with the old EC does not work either
(relay timeout, tach 0/0), so there is no easy downgrade path. Details and the freeze
steps we used: `docs/firmware.md`.

## Deploy

```sh
# 1. module autoload (the cooling device only exists while this is loaded)
sudo install -m 644 deploy/dgx_ec_fan_control.conf /etc/modules-load.d/dgx_ec_fan_control.conf
sudo modprobe dgx_ec_fan_control

# 2. userland controller: upstream checkout + this patch
git clone https://github.com/christopherowen/dgx-spark-fan-control
cd dgx-spark-fan-control && patch -p1 < /path/to/0001-performance-curve.patch
sudo install -m 755 userspace/dgx_fan_control.py /usr/local/sbin/dgx-fan-control

# 3. daemon
sudo install -m 644 deploy/dgx-fan-daemon.service /etc/systemd/system/dgx-fan-daemon.service
#    the upstream benchmark harness stops/starts "dgx-fan-control.service":
#    add the alias so that unit name resolves to the same daemon
sudo ln -sf /etc/systemd/system/dgx-fan-daemon.service /etc/systemd/system/dgx-fan-control.service
sudo systemctl daemon-reload
sudo systemctl enable --now dgx-fan-daemon.service

# 4. verify (this is the step people skip)
scripts/fan-snapshot.sh          # state, hottest zone, both fan RPMs, GPU clock/power
```

Leave the alias out at your own risk: if the unit name does not resolve, the upstream
benchmark aborts with `cannot restore fan control` and you get no measurement at all.

## Monitoring

- `scripts/fan-snapshot.sh` — read-only one-shot: requested state, hottest thermal zone,
  `fan1_input`/`fan2_input`, GPU temperature/clock/power. Safe to run from cron.
- `scripts/thermal-watch.sh` — alarm when ACPI ≥ 78 °C, GPU ≥ 75 °C, or the **current**
  fan state reads 0. Configuration is environment variables at the top of the file
  (host list, ssh user, alert file). Judge on the live state, not on the `baseline fan1=`
  line in `dmesg`: on one of our units the baseline is logged as 0 while the fans are
  running normally, which produced false alarms.

## Compatibility notes

- Works on our nodes with kernel `7.0.0-1019-nvidia-64k` (64 KB pages) and EC 3.5.8;
  upstream validates `6.17.0-1029-nvidia` with the same EC. Other kernels and any October
  firmware are unverified here.
- Measured with four nodes serving one tensor-parallel model; a single idle node behaves
  the same on temperature, but the RPM equilibrium differs because only one SoC is hot.
- The curve is an *additive floor*. It cannot make the fans quieter than the firmware
  wants, and it cannot exceed the firmware maximum. If you see the fans pinned at maximum
  with cool sensors, that is the firmware's own demand, not this patch.

## Credits and license

- `christopherowen/dgx-spark-fan-control` — the userland controller, kernel module and
  systemd unit this patch applies to (GPL-2.0). Only `PERFORMANCE_CURVE` is changed.
- `christopherowen/spark-ds41f` — the serving recipe we run; it intentionally leaves fan
  policy to the project above.
- Contributors: **tenhkspark** (measurements, curve, watchdog) and
  **DeepSeek V4.1 Flash 1017** (review and translation checks, run locally).

GPL-2.0, following upstream — see [LICENSE](LICENSE).
