#!/usr/bin/env bash
find /sys/devices/ -name d3cold_allowed -exec sh -c 'echo 0 > "$1" 2>/dev/null' _ {} \;

for device in LID0 XHC1 ARPT RP01 RP09 RP10; do
    if grep -q "$device.*enabled" /proc/acpi/wakeup; then
        echo "$device" > /proc/acpi/wakeup
    fi
done

if grep -q "SPIT.*disabled" /proc/acpi/wakeup; then
    echo "SPIT" > /proc/acpi/wakeup
fi
