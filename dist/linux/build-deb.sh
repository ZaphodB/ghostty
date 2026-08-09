#!/usr/bin/env bash
#
# Build a Debian/Ubuntu .deb of ghostty from the current source tree.
# Intended for local installs (apt install ./ghostty_<ver>_amd64.deb).
#
# Usage:
#   dist/linux/build-deb.sh            # builds and writes to dist-deb/
#   OUT=/tmp dist/linux/build-deb.sh   # override output directory
#
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

# Resolve zig.
if command -v zig >/dev/null 2>&1; then
    ZIG="$(command -v zig)"
elif [[ -x "$HOME/tmp/zig-toolchain/zig-x86_64-linux-0.15.2/zig" ]]; then
    ZIG="$HOME/tmp/zig-toolchain/zig-x86_64-linux-0.15.2/zig"
else
    echo "error: zig not found on PATH and no toolchain at ~/tmp/zig-toolchain" >&2
    exit 1
fi

# Version: upstream version from build.zig.zon plus the short git sha.
# Replace '-' with '~' so the upstream version stays a single Debian field.
upstream_ver="$(grep -E '^\s*\.version\s*=' build.zig.zon | head -1 \
                | sed -E 's/.*"([^"]+)".*/\1/' | tr '-' '~')"
short_sha="$(git rev-parse --short=9 HEAD)"
dirty=""
if ! git diff --quiet || ! git diff --cached --quiet; then
    dirty=".dirty"
fi
deb_version="${upstream_ver}+git${short_sha}${dirty}-1local"

arch="$(dpkg --print-architecture)"
out_dir="${OUT:-$repo_root/dist-deb}"
mkdir -p "$out_dir"

staging="$(mktemp -d -t ghostty-deb.XXXXXX)"
trap 'rm -rf "$staging"' EXIT

# Optimize/strip defaults match the mkasberg PPA recipe (ReleaseFast, stripped,
# PIE, hardening=+all) so the local build is binary-comparable to the stable
# PPA build. Override for diagnostics:
#   OPTIMIZE=ReleaseSafe STRIP=false dist/linux/build-deb.sh
optimize="${OPTIMIZE:-ReleaseFast}"
strip="${STRIP:-true}"

echo "==> building ghostty (this can take a while)"
# -fsys=fontconfig/harfbuzz/freetype: link the system shared libraries instead
# of letting Zig bundle and statically link its own. Bundling those causes a
# duplicate-globals crash because GTK transitively pulls in libfontconfig.so.1
# already, so the renderer thread ends up with two FcConfig states.
DEB_BUILD_MAINT_OPTIONS=hardening=+all DESTDIR="$staging" "$ZIG" build \
    --prefix /usr \
    -Doptimize="$optimize" \
    -Dcpu=baseline \
    -Dpie=true \
    -Dstrip="$strip" \
    -Demit-docs=false \
    -fsys=fontconfig \
    -fsys=freetype \
    -fsys=harfbuzz

# Minimum runtime depends. dpkg-shlibdeps would be more rigorous but pulls in
# debhelper machinery; this hand-rolled list is good enough for local installs
# on Ubuntu 24.04+ / Debian trixie.
depends="libc6, libgtk-4-1, libadwaita-1-0, libgtk4-layer-shell0, libgraphene-1.0-0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libfontconfig1, libfreetype6, libharfbuzz0b"

mkdir -p "$staging/DEBIAN"
installed_size_kb="$(du -sk "$staging/usr" | awk '{print $1}')"
cat > "$staging/DEBIAN/control" <<EOF
Package: ghostty
Version: ${deb_version}
Section: x11
Priority: optional
Architecture: ${arch}
Maintainer: Local Build <${USER}@$(hostname -f 2>/dev/null || hostname)>
Installed-Size: ${installed_size_kb}
Depends: ${depends}
Homepage: https://ghostty.org
Description: Fast, feature-rich, cross-platform terminal emulator
 Ghostty is a fast, feature-rich, and cross-platform terminal emulator that
 uses platform-native UI and GPU acceleration. This is a local build from
 source for personal use.
EOF

# dpkg-deb wants md5sums for the package contents.
( cd "$staging" && find usr -type f -print0 | xargs -0 md5sum > DEBIAN/md5sums )

deb_file="$out_dir/ghostty_${deb_version}_${arch}.deb"
echo "==> packaging $deb_file"
dpkg-deb --root-owner-group --build "$staging" "$deb_file" >/dev/null

echo
echo "Built: $deb_file"
echo "Install with: sudo apt install '$deb_file'"
