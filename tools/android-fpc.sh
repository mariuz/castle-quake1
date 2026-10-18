#!/usr/bin/env bash
# FPC cross-compilers for Android (arm and aarch64), for
# "castle-engine package --target=android".
#
#   tools/android-fpc.sh <prefix> <ndk dir>
#   source <prefix>/env.sh
#
# Builds ppcrossarm and ppcrossa64 from the sources of the installed FPC's
# version (fpc -iV, downloaded once) into <prefix>, with GNU binutils for
# assembling and linking (Debian / Ubuntu packages binutils-arm-linux-gnueabi
# and binutils-aarch64-linux-gnu: the NDK has no GNU binutils since r23, and
# FPC 3.2's Android linker script uses INSERT, which lld rejects). The
# libraries come from the NDK's sysroot for API 21: only its shared stubs,
# since the static libc.a there has symbol versions GNU ld cannot place.
# Writes <prefix>/cfg/fpc.cfg (the system fpc.cfg plus the Android units,
# binutils and library paths) and <prefix>/env.sh (PATH, PPC_CONFIG_PATH).
set -euo pipefail

PREFIX="${1:?usage: $0 <prefix> <ndk dir>}"
NDK="${2:?usage: $0 <prefix> <ndk dir>}"
mkdir -p "${PREFIX}"
PREFIX="$(cd "${PREFIX}" && pwd)"
FPC_VERSION="$(fpc -iV)"
COMPILERS="${PREFIX}/lib/fpc/${FPC_VERSION}"
SYSROOT_LIB="${NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"
API=21

for TOOL in arm-linux-gnueabi-as arm-linux-gnueabi-ld.bfd aarch64-linux-gnu-as aarch64-linux-gnu-ld.bfd; do
  if ! command -v "${TOOL}" > /dev/null; then
    echo "Missing ${TOOL}: install binutils-arm-linux-gnueabi and binutils-aarch64-linux-gnu"
    exit 1
  fi
done
for LIB in "${SYSROOT_LIB}/aarch64-linux-android/${API}/libc.so" "${SYSROOT_LIB}/arm-linux-androideabi/${API}/libc.so"; do
  if [ ! -f "${LIB}" ]; then
    echo "Missing ${LIB}: is ${NDK} an Android NDK?"
    exit 1
  fi
done

# The cross-compilers (kept when they exist, e.g. from a CI cache)
if [ ! -x "${COMPILERS}/ppcrossa64" ] || [ ! -x "${COMPILERS}/ppcrossarm" ]; then
  SRC="${PREFIX}/src"
  mkdir -p "${SRC}"
  if [ ! -d "${SRC}/fpc-${FPC_VERSION}" ]; then
    curl -sSfL -o "${SRC}/fpc.tar.gz" \
      "https://downloads.sourceforge.net/project/freepascal/Source/${FPC_VERSION}/fpc-${FPC_VERSION}.source.tar.gz"
    tar xzf "${SRC}/fpc.tar.gz" -C "${SRC}"
    rm -f "${SRC}/fpc.tar.gz"
  fi
  cd "${SRC}/fpc-${FPC_VERSION}"
  make clean crossinstall OS_TARGET=android CPU_TARGET=aarch64 CROSSBINDIR=/usr/bin \
    BINUTILSPREFIX=aarch64-linux-gnu- INSTALL_PREFIX="${PREFIX}" PP="$(command -v fpc)" > "${PREFIX}/build-aarch64.log" 2>&1
  make clean crossinstall OS_TARGET=android CPU_TARGET=arm CROSSOPT="-CpARMV7A -CfVFPV3" CROSSBINDIR=/usr/bin \
    BINUTILSPREFIX=arm-linux-gnueabi- INSTALL_PREFIX="${PREFIX}" PP="$(command -v fpc)" > "${PREFIX}/build-arm.log" 2>&1
  cd - > /dev/null
  rm -Rf "${SRC}"
fi

# The binutils under the names the configuration below gives FPC
mkdir -p "${PREFIX}/bin"
for PAIR in arm:arm-linux-gnueabi a64:aarch64-linux-gnu; do
  SHORT="${PAIR%%:*}"
  GNU="${PAIR#*:}"
  ln -sf "$(command -v "${GNU}-as")" "${PREFIX}/bin/android-${SHORT}-as"
  ln -sf "$(command -v "${GNU}-ld.bfd")" "${PREFIX}/bin/android-${SHORT}-ld"
  ln -sf "$(command -v "${GNU}-ld.bfd")" "${PREFIX}/bin/android-${SHORT}-ld.bfd"
done

SYSTEM_CFG=/etc/fpc.cfg
if [ ! -f "${SYSTEM_CFG}" ]; then
  SYSTEM_CFG="$(dirname "$(command -v fpc)")/../etc/fpc.cfg"
fi
mkdir -p "${PREFIX}/cfg"
cat > "${PREFIX}/cfg/fpc.cfg" <<CFG
#include ${SYSTEM_CFG}
#ifdef android
-Fu${PREFIX}/lib/fpc/\$fpcversion/units/\$fpctarget/*
-FD${PREFIX}/bin
#ifdef cpuaarch64
-XPandroid-a64-
-Fl${SYSROOT_LIB}/aarch64-linux-android/${API}
#endif
#ifdef cpuarm
-XPandroid-arm-
-Fl${SYSROOT_LIB}/arm-linux-androideabi/${API}
#endif
#endif
CFG

cat > "${PREFIX}/env.sh" <<ENV
export PATH="${COMPILERS}:\${PATH}"
export PPC_CONFIG_PATH="${PREFIX}/cfg"
ENV
echo "FPC ${FPC_VERSION} cross-compilers for Android in ${COMPILERS}; source ${PREFIX}/env.sh"
