# The curve, and how to move it

`PERFORMANCE_CURVE` in `userspace/dgx_fan_control.py` is the only thing this repository
changes. Everything else (smoothing, rate limits, hysteresis, failure handling) is
upstream and stays that way.

## State to RPM

The controller writes a *state* 0–12; the firmware turns it into a floor and keeps the
higher of that floor and its own demand. Upstream documents the mapping
(`docs/usage.md`), repeated here because every number below depends on it:

| State | Common floor | State | Common floor |
|---|---|---|---|
| 0 | NVIDIA automatic (no floor) | 7 | 8,100 RPM |
| 1 | 2,700 RPM | 8 | 9,000 |
| 2 | 3,600 | 9 | 10,125 |
| 3 | 4,500 | 10 | 11,250 |
| 4 | 5,400 | 11 | 12,375 |
| 5 | 6,300 | 12 | 13,500 |
| 6 | 7,200 | | |

Fan 1 tops out around 9,000 RPM, fan 2 around 13,500: above state 8 only the second fan
gets faster.

## Upstream curve vs this patch

```
upstream                          this patch
(50.0, 3)   4,500 at 50 °C        (0.0, 1)    2,700 always
(55.0, 5)   6,300 at 55 °C        (52.0, 2)   3,600 at 52 °C
(60.0, 8)   9,000 at 60 °C        (57.0, 3)   4,500 at 57 °C
(65.0, 10) 11,250 at 65 °C        (62.0, 4)   5,400 at 62 °C
(70.0, 12) 13,500 at 70 °C        (66.0, 5)   6,300 at 66 °C
                                  (70.0, 6)   7,200 at 70 °C
                                  (73.0, 8)   9,000 at 73 °C
                                  (76.0, 10) 11,250 at 76 °C
                                  (78.0, 12) 13,500 at 78 °C
```

Two separate ideas are mixed in that change; keep them apart when you edit it:

1. **A floor that cannot be zero.** `(0.0, 1)` means the daemon always asks for at least
   2,700 RPM. Upstream's first entry starts at 50 °C, so below that the requested state is
   0 (NVIDIA automatic). With the daemon wedged or stopped, state 0 is exactly the state
   we saw produce 0 RPM. The floor costs 2,700 RPM at idle and removes the trap.
2. **A curve pushed to the hot side.** Between 52 °C and 78 °C we request less cooling than
   upstream at every point, and reach full speed at 78 °C instead of 70 °C. The upper end
   is deliberately unchanged in *maximum*: our alarm lines are ACPI 78 °C / GPU 75 °C, so
   the top few degrees must be full fan.

## Shifting it yourself

- Quieter (hotter): raise every threshold by 1–2 °C, keep `(0.0, 1)`, and keep the last
  point at or below your alarm line. Watch ACPI during a real job for a day before trusting it.
- Cooler (safer): shift the middle down toward the upstream values. The upstream curve is
  a reasonable ceiling on how aggressive you want to be; going further just raises noise
  for no measurable speed gain (see the measurements in README).
- Do not add a point above your alarm threshold: the last row is what runs when something
  goes wrong, and it should be maximum cooling, not "a bit more".

The constants that shape *how fast* the state moves are upstream's and worth knowing:
`FILTER_ALPHA=0.35` (exponential smoothing of the hottest zone), up to +2 states per 2 s
sample, −1 state per sample, `DOWN_HYSTERESIS_C=4.0`, and state 12 after three consecutive
transport failures. A sudden load therefore takes a couple of samples to be reflected, and
a falling temperature lags by the hysteresis on purpose.

## Verifying a change

```sh
scripts/fan-snapshot.sh          # before
# run the real workload for at least ten minutes
scripts/fan-snapshot.sh          # during, and again a minute after it ends
```

What "fine" looked like on our four nodes: idle state 2 at ACPI 50–53 °C, mid load
(2 × 700-token generations per node) ACPI 65–73 °C with state 5–6, and generation speed
unchanged against the upstream curve (700 tokens in 10.7–10.9 s, 400 tokens in 5.6 s).

If a change makes the job slower, stop and look at **fan RPM and the ACPI zones**, not the
GPU temperature: a clamped GPU (611 MHz, 8–11 W, high utilisation, no thermal-slowdown
flag) is what a stopped fan looks like from `nvidia-smi`.
