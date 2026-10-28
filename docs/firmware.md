# Firmware: which set keeps fan control working

Fan control on the DGX Spark goes through EC mailboxes. The October 2026 firmware set
removed or locked the paths the userland controller depends on, so the practical rule is:
**stay on the September set until NVIDIA ships a fix**.

## Versions as reported by fwupd on our units (2026-10-28, before we froze updates)

| Component | September 2026 — fan control works | October 2026 — fan control breaks |
|---|---|---|
| EC | 3.5.8 — `0x03000508` | 3.13.7 — `0x03000d07` |
| SoC | 2.155.11 — `0x02009b0b` | 2.158.15 — `0x02009e0f` |
| USB-C PD | 5.22 — `0x00000516` | 5.25 — `0x00000519` |
| BIOS (unchanged) | 5.36_0ACUM027 | 5.36_0ACUM027 |

## What the October set actually does

- Floor writes (commands 3 and 5) return `0xff`; reads come back as `0xffff`.
- The override path is gone from the firmware.
- The fan range is clamped to **975–4,350 RPM**, against 1,260–9,000 (fan 1) and
  1,890–13,500 (fan 2) on the September set.
- New SoC + old EC does not work either: relay timeout and `tach 0/0`. So once you take
  the October SoC there is no easy way back to a working combination.

NVIDIA has stated it will not hand out firmware signing keys for custom builds, so a
downstream workaround is not available at this time.

## Reading what you have

```sh
cat /sys/class/dmi/id/bios_version          # BIOS, no root needed
sudo fwupdmgr get-devices                   # EC / SoC / USB-C PD rows, needs the LVFS remote
sudo fwupdmgr get-updates                   # "no updates" once the freeze below is in place
```

`fwupdmgr` only lists the EC/SoC/PD components while the LVFS remote and its metadata are
present. After the freeze below they disappear from the list — the versions in the table
were captured before it. If you need to read them again, re-enable the remote
(`fwupdmgr enable-remote lvfs`), read, and disable it again; do not run `refresh` while it
is enabled or you will download the October metadata again.

## Freezing the firmware (what we did on all four nodes)

```sh
sudo fwupdmgr disable-remote lvfs --assume-yes   # also drops cached metadata
sudo systemctl mask fwupd-refresh.timer fwupd-refresh.service
sudo sh -c 'printf "0.0.0.0 lvfs.fwupd.org\n0.0.0.0 cdn.fwupd.org\n" >> /etc/hosts'
```

Verify: `sudo fwupdmgr get-updates` reports nothing new, `systemctl is-enabled
fwupd-refresh.timer` says `masked`, and `dgx-fan-daemon` is active.

What this does **not** cover:

- apt security updates keep flowing (unchanged); EC/SoC/PD only arrive through LVFS.
- The DGX OS OTA metadata package (`dgx-spark-ota-update-meta`, 26.09.3 at the time) is not
  held: OS updates are allowed, and the hosts entries still block a re-fetch of the
  firmware payload.
- `fwupdmgr` run by hand can undo this in two steps. There is no guard on top; the point
  is to make the unsafe path deliberate rather than automatic.

## Unfreezing later

```sh
sudo sed -i '/lvfs.fwupd.org/d;/cdn.fwupd.org/d' /etc/hosts
sudo systemctl unmask fwupd-refresh.timer fwupd-refresh.service
sudo fwupdmgr enable-remote lvfs --assume-yes
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates      # read what it wants before installing anything
```

Take the October set only once NVIDIA documents that fan override works again **and** the
userland controller you use is confirmed against that version.

## Further reading

- NVIDIA developer forum thread on fan control via the kernel module (the October
  regression is discussed there): <https://forums.developer.nvidia.com/t/382536/4>
- NVIDIA's answer on signing keys / developer mode for DGX Spark firmware:
  <https://forums.developer.nvidia.com/t/385314/2>
- Upstream project: <https://github.com/christopherowen/dgx-spark-fan-control>
  (`docs/firmware-pending-analysis.md` goes deeper into the protocol)
