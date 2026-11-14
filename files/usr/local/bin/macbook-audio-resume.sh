#!/usr/bin/env bash
# Re-initialise the CS8409 (snd_hda_macbookpro) after resume.
# Runs after systemd-sleep has thawed user processes, so PipeWire can release the card.
DEV=0000:00:1f.3
if [ -e /sys/bus/pci/drivers/snd_hda_intel/$DEV ]; then
    echo $DEV > /sys/bus/pci/drivers/snd_hda_intel/unbind
fi
# The driver overwrites its own ops table on first probe, so it must be reloaded before re-probing
modprobe -r snd_hda_codec_cs8409
modprobe snd_hda_codec_cs8409
# Re-binding re-applies hda-macbookpro.fw, restoring the subsystem ID lost in S3
echo $DEV > /sys/bus/pci/drivers/snd_hda_intel/bind
