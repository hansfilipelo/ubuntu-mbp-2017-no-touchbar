#!/usr/bin/env bash
# Set up Ubuntu on a MacBook Pro 13" 2017 without Touch Bar (MacBookPro14,1, A1708).
#
# Installs build requirements, fetches and builds the out-of-tree drivers
# (CS8409 audio, FaceTime HD camera + firmware) and copies all configs into place.
# Safe to re-run, e.g. after a kernel update (the drivers are built per kernel).
#
# Usage: sudo ./install.sh [--configs-only] [--force]
#   --configs-only  only copy configs (skip packages and driver builds)
#   --force         run even if this is not a MacBookPro14,1
set -euo pipefail

# Upstream repos. By default the latest commit of each repo's default branch is used;
# set *_REF to a branch, tag or commit to pin one instead.
SND_HDA_REPO=${SND_HDA_REPO:-https://github.com/davidjo/snd_hda_macbookpro.git}
SND_HDA_REF=${SND_HDA_REF:-}
FTHD_REPO=${FTHD_REPO:-https://github.com/patjak/facetimehd.git}
FTHD_REF=${FTHD_REF:-}
FTHD_FW_REPO=${FTHD_FW_REPO:-https://github.com/patjak/facetimehd-firmware.git}
FTHD_FW_REF=${FTHD_FW_REF:-}

SRC_DIR=${SRC_DIR:-/usr/local/src/mbp-2017-setup}
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FILES_DIR=$REPO_DIR/files
KVER=$(uname -r)

CONFIGS_ONLY=0
FORCE=0
for arg in "$@"; do
    case $arg in
        --configs-only) CONFIGS_ONLY=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 $*" >&2; exit 1; }

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
if [[ $model != MacBookPro14,1 && $FORCE -eq 0 ]]; then
    echo "This machine is '$model', not MacBookPro14,1. The audio pin layout and" >&2
    echo "PCI addresses are specific to that model. Use --force to continue anyway." >&2
    exit 1
fi

# --- helpers -----------------------------------------------------------------

fetch() { # fetch <repo-url> <ref, empty = remote default branch> <dir>
    local url=$1 ref=$2 dir=$3
    if [[ ! -d $dir/.git ]]; then
        git clone --quiet "$url" "$dir"
    fi
    git -C "$dir" fetch --quiet --tags origin
    if [[ -z $ref ]]; then
        # Follow whatever upstream calls its default branch (main/master/trunk)
        git -C "$dir" remote set-head origin --auto >/dev/null
        ref=origin/HEAD
    elif git -C "$dir" rev-parse --verify --quiet "origin/$ref" >/dev/null; then
        ref=origin/$ref   # a branch name: use the freshly fetched remote branch
    fi
    git -C "$dir" checkout --quiet --force --detach "$ref"
    git -C "$dir" clean --quiet -fdx
    echo "  $(basename "$dir"): $(git -C "$dir" log -1 --format='%h %cd %<(60,trunc)%s' --date=short)"
}

install_packages() {
    log "Installing build requirements"
    local ksrc="linux-source-${KVER%%-*}"   # e.g. linux-source-7.0.0
    apt-get update
    apt-get install -y build-essential git patch curl xz-utils cpio kmod \
        "linux-headers-$KVER" "$ksrc"
}

install_audio_driver() {
    log "Building CS8409 audio driver (snd_hda_macbookpro) for $KVER"
    fetch "$SND_HDA_REPO" "$SND_HDA_REF" "$SRC_DIR/snd_hda_macbookpro"
    # The upstream script uses paths relative to its own directory
    (cd "$SRC_DIR/snd_hda_macbookpro" && bash ./install.cirrus.driver.sh)
}

install_camera() {
    log "Extracting FaceTime HD camera firmware (downloads from Apple's CDN)"
    fetch "$FTHD_FW_REPO" "$FTHD_FW_REF" "$SRC_DIR/facetimehd-firmware"
    make -C "$SRC_DIR/facetimehd-firmware"
    make -C "$SRC_DIR/facetimehd-firmware" install

    log "Building FaceTime HD camera driver (facetimehd) for $KVER"
    fetch "$FTHD_REPO" "$FTHD_REF" "$SRC_DIR/facetimehd"
    make -C "$SRC_DIR/facetimehd" KVERSION="$KVER"
    make -C "$SRC_DIR/facetimehd" KVERSION="$KVER" install
}

install_configs() {
    log "Copying configs"
    # Mirror files/ onto /: executables get 755, everything else 644
    (cd "$FILES_DIR" && find . -type f) | while read -r f; do
        f=${f#./}
        if [[ -x $FILES_DIR/$f ]]; then mode=755; else mode=644; fi
        install -D -m "$mode" "$FILES_DIR/$f" "/$f"
        echo "  /$f"
    done

    # Leftovers from earlier attempts that are now wrong or superseded
    local obsolete=(
        /etc/udev/rules.d/99-macbook-thunderbolt-pm.rules   # did not help: firmware, not Linux, powers TB off
    )
    for f in "${obsolete[@]}"; do
        if [[ -e $f ]]; then rm -f "$f"; echo "  removed obsolete $f"; fi
    done
}

activate() {
    log "Activating"
    depmod -a "$KVER"
    systemctl daemon-reload
    systemctl enable macbook-audio-resume.service
    update-initramfs -u -k "$KVER"   # picks up the modprobe.d changes
    update-grub                      # picks up /etc/default/grub.d/90-macbookpro.cfg
}

# --- main --------------------------------------------------------------------

if [[ $CONFIGS_ONLY -eq 0 ]]; then
    mkdir -p "$SRC_DIR"
    install_packages
    install_audio_driver
    install_camera
fi
install_configs
activate

log "Done. Reboot to apply everything."
if grep -qE 'intel_iommu=off' /etc/default/grub 2>/dev/null; then
    echo "Note: /etc/default/grub already contains the kernel parameters by hand;"
    echo "      /etc/default/grub.d/90-macbookpro.cfg will not duplicate them."
fi
