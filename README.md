# Ubuntu on MacBook Pro 13" 2017, no Touch Bar (MacBookPro14,1 / A1708)

Scripts and configs to get Wi-Fi, audio, the FaceTime HD camera and suspend/resume
working on this model. Tested on Ubuntu 26.04.1 LTS with kernel 7.0.0-43-generic.

This is currently HEAVILY AI generated config and code, but it is baseed on what
I ended up with on my running system.

Based on [alioalyasari/macbookpro-a1708-ubuntu](https://github.com/alioalyasari/macbookpro-a1708-ubuntu),
with fixes for the problems that guide leaves open (audio after suspend, Wi-Fi driver
reload on newer kernels, slow resume).

## Install

```sh
git clone <this repo> && cd mbp-2017-no-touch-bar-ubuntu-config
sudo ./install.sh
sudo reboot
```

`install.sh` does the following:

1. Installs build requirements (`build-essential`, kernel headers, the Ubuntu
   `linux-source` package the audio driver is built from, `curl`/`xz-utils`/`cpio` for
   the camera firmware).
2. Fetches, builds and installs the latest commit on the default branch of
   - [davidjo/snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro) (CS8409 audio),
   - [patjak/facetimehd-firmware](https://github.com/patjak/facetimehd-firmware) (camera firmware, downloaded from Apple),
   - [patjak/facetimehd](https://github.com/patjak/facetimehd) (camera driver).
   Sources go to `/usr/local/src/mbp-2017-setup`.
3. Copies everything under [`files/`](files) to the same path under `/`.
4. Runs `depmod`, enables the audio resume service, and updates the initramfs and GRUB.

Options:

- `--configs-only`: only step 3 and 4.
- `--force`: run on a different model. Not recommended: the audio patch file and PCI addresses are for this model only.

The installer prints the commit it built for each repo. If a new upstream commit
breaks something, pin a branch, tag or commit with an environment variable
(`SND_HDA_REF`, `FTHD_REF`, `FTHD_FW_REF`), e.g.
`sudo SND_HDA_REF=89b22ff ./install.sh`. That is the snd_hda_macbookpro commit tested
with kernel 7.0.0-43 (facetimehd: `4e588ae`, facetimehd-firmware: `961774d`).

**After every kernel update**, re-run `sudo ./install.sh`. The audio and camera
drivers are built for one kernel version and aren't rebuilt automatically.

## What gets installed

| Path | Purpose |
|---|---|
| `/etc/default/grub.d/90-macbookpro.cfg` | Kernel parameters (see below); skips any already in `/etc/default/grub` |
| `/etc/modprobe.d/disable-thunderbolt.conf` | Blacklists the `thunderbolt` driver (from the original guide) |
| `/etc/modprobe.d/hda-macbookpro.conf` | Makes `snd-hda-intel` load the audio patch file |
| `/usr/lib/firmware/hda-macbookpro.fw` | Restores the CS8409 audio chip's ID and pin layout (see [Audio](#audio-silent-after-suspend)) |
| `/etc/systemd/sleep.conf.d/90-macbookpro.conf` | Plain S3 suspend, no suspend-then-hibernate |
| `/usr/local/bin/tm-suspend-fix.sh` | Disables noisy ACPI wake sources and PCIe D3cold before sleep (from the original guide) |
| `/usr/lib/systemd/system-sleep/tm-suspend-fix` | Sleep hook: unloads and reloads Wi-Fi and keyboard drivers, handles Thunderbolt |
| `/usr/local/bin/macbook-audio-resume.sh` + `/etc/systemd/system/macbook-audio-resume.service` | Resets the audio chip after wake |

Kernel parameters: `intel_iommu=off acpi_sleep=nonvs button.lid_init_state=open
nvme_core.default_ps_max_latency_us=0 nvme.noacpi=1 pci=noaer i915.enable_dc=0
i915.enable_fbc=0 i915.enable_psr=0`.

## Problems and how they're fixed

### Wi-Fi dead after suspend

The BCM4350 loses its firmware state in S3. Afterwards the `brcmfmac` driver only logs
`brcmf_msgbuf_query_dcmd: Timeout on response`. The fix is to unload the driver before
sleep and load it again after wake.

On current kernels `brcmfmac` is split into `brcmfmac` and the vendor module
`brcmfmac_wcc`, which keeps the core module in use. The original guide's
`modprobe -r brcmfmac` therefore fails with `Module brcmfmac is in use`. The hook unloads
both with `modprobe -r brcmfmac_wcc brcmfmac` and loads both with `modprobe -a`. Plain
`modprobe brcmfmac brcmfmac_wcc` would treat the second name as a module parameter.

### Audio silent after suspend

The internal speakers need the patched CS8409 driver from snd_hda_macbookpro.
Its README says suspend is untested, and four separate things break:

1. **The chip forgets its identity.** Apple firmware programs the codec's subsystem
   ID (`0x106b3300`) and pin layout at power-on. S3 cuts power to the chip, so after wake
   it reports the default ID `0x10138409` and every pin as "not connected". The driver
   then rejects the chip (`UNKNOWN subsystem id`), or finds no outputs. Its resume handler
   calls an empty `init()`, so it never sets the chip up again.
   **Fix:** `hda-macbookpro.fw` is an HDA *patch file* that sets `[subsystem_id]` and
   `[pincfg]` to the values the firmware uses. The kernel applies it every time
   `snd-hda-intel` probes the controller. At boot it sets the same values the firmware
   already set, so it changes nothing there.
2. **The driver can only probe once per module load.** Its Apple code path overwrites
   the module-global `driver->ops` with a table that has no `.probe`, so every later probe
   hits `WARN_ON(!(driver->ops && driver->ops->probe))` in `sound/hda/common/bind.c`
   and fails with `-22`. **Fix:** reload `snd_hda_codec_cs8409` before re-probing.
3. **The generic fallback gets stuck.** If the Mac driver fails once, the kernel binds
   `snd_hda_codec_generic` and sets `codec->probe_id = HDA_CODEC_ID_GENERIC`. That ID is
   kept for the life of the codec object, so binding the Mac driver by hand won't match.
   Only unbinding and rebinding the whole PCI controller creates a fresh codec object.
4. **It can't run inside the sleep hook.** systemd freezes user processes while
   `system-sleep` hooks run. Unbinding the card waits for PipeWire to close its PCM, but
   PipeWire is frozen, so the hook hangs until systemd's timeout and is killed half-way.
   **Fix:** `macbook-audio-resume.service` (`After=suspend.target`) runs the
   unbind → reload module → bind sequence once user processes are running again.

To regenerate the pin values (e.g. for another model with a CS8409), read them **after
a fresh boot, before any suspend**:

```sh
cat /sys/class/sound/hwC0D0/subsystem_id
cat /sys/class/sound/hwC0D0/init_pin_configs
```

### Slow wake: fixed delays in the sleep hook

The original hook slept 5 + 3 + 2 seconds and toggled the Wi-Fi radio. User processes
stay frozen until the hook returns, so this kept the desktop unresponsive for about 10 s
after wake. The delays aren't needed: the hook only runs once the kernel has finished
resuming, and NetworkManager picks up the reloaded Wi-Fi device by itself. Removing them
brings the time until the desktop responds down to about 0.5 s.

### Slow wake: Thunderbolt (~65 s with the display off) — *untested fix*

The Thunderbolt chip (Alpine Ridge, behind both USB-C ports) loses power in S3. With the
`thunderbolt` driver blacklisted, nothing powers it back on. On the **first** wake after
boot the whole chain is gone: every device reports `Unable to change power state …
device inaccessible`, its USB controller (`07:00.0`) is removed, and USB-C data devices
disconnect. Charging keeps working. This wake is still quick. The dead devices keep
reading `0xffff`, while Linux still lists the switch as active. On the **second** wake
the kernel waits on them:

```
pcieport 0000:04:00.0: not ready 1023ms after resume; waiting
...
pcieport 0000:04:00.0: not ready 65535ms after resume; giving up
```

**Fix (not yet tested):** before sleep, the hook checks whether the Thunderbolt switch
`0000:04:00.0` still responds. If it reads `0xffff`, the hook removes it from the PCI
tree, so the kernel has nothing to wait for on wake. The hardware is already dead at that
point, so nothing is lost. Look for `Removed unpowered Thunderbolt switch` in
`/tmp/suspend.log`.

Keeping the ports out of runtime power management (`power/control=on`) doesn't help:
the firmware powers them off, not Linux. The installer removes an earlier udev rule that
tried this.

USB-C *data* (not charging) stops working after the first suspend until the
next reboot, whether or not this fix is installed. The `thunderbolt` driver is what
would normally power the chip back on. Removing the blacklist might fix both problems,
but could bring back whatever suspend problem the original guide blacklisted it for.
The guide doesn't say what that was, so test it on its own.

## Troubleshooting

```sh
# Timeline of the last suspend/resume
journalctl -b -o short-precise | grep -E 'PM: suspend|returned from sleep|thawed unit|macbook-audio'
# Audio: driver probe and patch file
journalctl -b -k | grep -E 'patch firmware|Primary cs8409|UNKNOWN subsystem|autoconfig'
# Thunderbolt stall
journalctl -b -k | grep -E 'not ready .* after resume'
cat /tmp/suspend.log
```

If audio is still silent after waking, resetting the audio chip by hand usually brings it back:

```sh
sudo systemctl start macbook-audio-resume.service
```
