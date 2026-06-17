#!/usr/bin/env bash
#
# Install pre-compiled Livox SDK2 to /usr/local.
# Usage: bash livox_sdk_install.sh
#
# These files were scp'd from a {DEVICE} Jetson (aarch64) after building
# Livox-SDK2 from source.  Bundling avoids having to clone, cmake,
# and build on a fresh device.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_LIB="$SELF_DIR/livox_sdk"
SRC_INC="$SELF_DIR/livox_sdk"

echo "[livox_sdk_install] Installing SDK to /usr/local ..."

sudo cp -v "$SRC_LIB"/liblivox_lidar_sdk_static.a /usr/local/lib/
sudo cp -v "$SRC_LIB"/liblivox_lidar_sdk_shared.so /usr/local/lib/
sudo cp -v "$SRC_INC"/livox_lidar_def.h   /usr/local/include/
sudo cp -v "$SRC_INC"/livox_lidar_api.h   /usr/local/include/
sudo cp -v "$SRC_INC"/livox_lidar_cfg.h   /usr/local/include/

sudo ldconfig

echo "[livox_sdk_install] Done."
ls -la /usr/local/lib/liblivox_lidar_sdk_*
ls -la /usr/local/include/livox_lidar_*
