#!/bin/bash
###############################################################################################################
# Compile a static RSYNC binary for use with VMware ESXi (6,7,8 & 9) from Fedora 42 system packages
# David Harrop
# September 2025
###############################################################################################################

## Build Instructions
# 1. On a fresh Fedora 42 system, run the build script (not as sudo or root) ./rsync-esxi-builder-fedora42.sh
#
# 2. When the script completes, copy the compiled rsync binary from $HOME/build-static/bin to 
#    	all source & destination ESXi hosts** (note the install path of each - you will need this later)
#
# 3. On each ESXi host, set execute permissions on the binary: chmod 755 /path/to/rsync
#
# 4. For ESXi 8 and above only – you must also allow execution of non-native binaries:
#    	esxcli system settings advanced set -o /User/execInstalledOnly -i 0
#
# 5. Configure RSA SSH keys for passwordless SSH authentication. 
# 		(VMware does not currently support Ed25519 keys for Esxi host to host sessions.)
#
# 6. Look to the usage examples on https://github.com/itiligent/RSYNC-ESXi?tab=readme-ov-file#-usage-examples

set -eu

clear

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m"  # No colour

echo
echo "### Rsync for Esxi build script ###"
echo

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}Error: This script should NOT be run as root or with sudo.${NC}"
    exit 1
fi

RSYNC_VER="3.4.1"			# Set the rsync version to build
OPENSSL_VER="1.1.1w"		# Legacy 1.1.1w is more compatible with legacy crypto algorithyms
XXHASH_VER="0.8.3"

WORKDIR=$HOME/build-static
PREFIX=$WORKDIR/prefix
OPENSSL=$WORKDIR/openssl
RSYNC=$WORKDIR/rsync
XXHASH=$WORKDIR/xxhash

mkdir -p $WORKDIR $PREFIX $OPENSSL $RSYNC $XXHASH
cd $WORKDIR


# Install essential build tools
sudo dnf -y update && sudo dnf -y install \
curl zlib-devel zlib-static lz4-devel lz4-static python3-pip automake \
libzstd-static libzstd-devel popt-devel popt-static perl glibc-static
python3 -m pip install --user commonmark


# 1. Build OpenSSL (static)
if [ ! -f $OPENSSL/lib/libssl.a ]; then
	echo
	echo "### Building static openssl ###"
	echo

	curl -LO https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz
	tar -xzf openssl-$OPENSSL_VER.tar.gz
	cd openssl-$OPENSSL_VER
	./Configure linux-x86_64 no-shared no-dso no-async \
	no-comp no-hw no-tests no-afalgeng -DOPENSSL_NO_SECURE_MEMORY --prefix=$OPENSSL	
	make -j$(nproc)
	make install_sw
	cd ..
fi


# 2. Build xxHash (static)

if [ ! -f $XXHASH/lib/libxxhash.a ]; then
echo
echo "### Building static xxhash ###"
echo
	curl -LO https://github.com/Cyan4973/xxHash/archive/refs/tags/v$XXHASH_VER.tar.gz
	tar -xzf v$XXHASH_VER.tar.gz
	cd xxHash-$XXHASH_VER
	mkdir -p $XXHASH/lib $XXHASH/include
	make -j$(nproc)
	cp libxxhash.* $XXHASH/lib/
	cp *.h $XXHASH/include/
	cd ..
fi


# 3. Build rsync (static)
echo
echo "### Building static rsync ###"
echo
	curl -LO https://github.com/RsyncProject/rsync/archive/refs/tags/v$RSYNC_VER.tar.gz
	tar -xzf v$RSYNC_VER.tar.gz
	cd rsync-$RSYNC_VER
	export PKG_CONFIG_PATH=$OPENSSL/lib/pkgconfig
	export CFLAGS="-I/usr/include -I/usr/include/lz4 -I$XXHASH/include -I/usr/include/zstd -I$OPENSSL/include -std=c99 -O2"
	export LDFLAGS="-L$OPENSSL/lib -L$XXHASH/lib -static -ldl -lpthread -lm"
	./configure --prefix=$RSYNC --disable-md2man --with-included-zlib=no
    make -j$(nproc)
    make install
	strip --strip-all $RSYNC/bin/rsync
    cd ..

# 4. Verify and report
RSYNC_BIN="$RSYNC/bin/rsync"

echo
echo -e "${GREEN}Static rsync build complete!${NC}"
echo

FILE_INFO=$(file "$RSYNC_BIN")
if echo "$FILE_INFO" | grep -q "statically linked"; then
	echo -e "${CYAN}New rsync binary build info:"
    echo -e "${GREEN}${FILE_INFO}${NC}"
else
    echo -e "${RED}${FILE_INFO} (Warning: not fully static)${NC}"
fi
echo

echo -e "${CYAN}Checking rsync for dynamic libraries (should be none for a static build):${NC}"
ldd "$RSYNC_BIN" 2>/dev/null || echo -e "${YELLOW}No dynamic dependencies - this is good!${NC}"
echo

echo -e "${CYAN}File details:${NC}"
ls -lh "$RSYNC_BIN"
echo

echo -e "${CYAN}If successful, 'binary build info' output above should say 'statically linked'."
echo -e "${GREEN}New binary location: ${RSYNC_BIN}${NC}"
echo

