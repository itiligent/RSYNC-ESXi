#!/bin/bash
###############################################################################################################
# Compile a static RSYNC binary (ALL FROM SOURCE) for use with VMware ESXi (6,7,8 & 9 )
# David Harrop
# September 2025
###############################################################################################################

## Build Instructions
# 1. This script is tested on Debian 13/Ubuntu 24 and Fedora 42. It should work with any Redhat flavored distro
# 	 that supports glibc-static. For a full RedHat flavoured list see here: https://pkgs.org/download/glibc-static
#
# 2. Run the build script NOT as sudo or root ./rsync-esxi-builder-multiOS.sh
#
# 3. When the script completes, copy the compiled rsync binary from $HOME/build-static/bin to 
#    	all source & destination ESXi hosts** (note the install path of each - you will need this later)
#
# 4. On each ESXi host, set execute permissions on the binary: chmod 755 /path/to/rsync
#
# 5. For ESXi 8 and above only – you must also allow execution of non-native binaries:
#    	esxcli system settings advanced set -o /User/execInstalledOnly -i 0
#
# 6. Configure RSA SSH keys for passwordless SSH authentication
# 		(VMware does not currently support Ed25519 keys for Esxi host to host sessions.)
#
# 7. Look to https://github.com/itiligent/RSYNC-ESXi/blob/main/rsync-host-2-host.sh for the companion replication script

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

RSYNC_VER="3.2.7"  # rsync version to build
ZLIB_VER="1.3.1"
LZ4_VER="1.10.0"
ZSTD_VER="1.5.7"
OPENSSL_VER="1.1.1w" # older versions more compatible with rsync & legacy md5
POPT_VER="1.19"
XXHASH_VER="0.8.3"

WORKDIR=$HOME/build-static
PREFIX=$WORKDIR/prefix
ZLIB=$WORKDIR/zlib
LZ4=$WORKDIR/lz4
ZSTD=$WORKDIR/zstd
OPENSSL=$WORKDIR/openssl
POPT=$WORKDIR/popt
RSYNC=$WORKDIR/rsync
XXHASH=$WORKDIR/xxhash

mkdir -p $WORKDIR $PREFIX $ZLIB $LZ4 $ZSTD $OPENSSL $POPT $RSYNC $XXHASH
cd $WORKDIR

# Function to install dependencies on Red Hat-based systems
install_redhat() {
    echo "Detected Red Hat-based system. Installing dependencies..."
	echo
    sudo yum -y update
    sudo yum -y install curl python3-pip automake perl gcc glibc-static
    python3 -m pip install --user commonmark
}

# Function to install dependencies on Debian-based systems
install_debian() {
    echo "Detected Debian-based system. Installing dependencies..."
	echo
    sudo apt update
    sudo apt install -y curl python3-venv python3-pip build-essential automake pkg-config libssl-dev

    # Create and activate Python venv
    python3 -m venv "$VENV"
    source "$VENV/bin/activate"

    # Install Python packages in the venv
    pip install --upgrade pip
    pip install commonmark
}

# Detect the package manager and install dependencies accordingly
if command -v yum >/dev/null 2>&1; then
    install_redhat
	
elif command -v apt >/dev/null 2>&1; then
	VENV=$WORKDIR/venv
    mkdir -p $WORKDIR/venv
    install_debian
else
    echo "Unsupported system. Please install dependencies manually."
    exit 1
fi

echo "All dependencies installed successfully!"
echo

# 1. Build zlib from source (static) [alt Fedora42 pakages are zlib-devel zlib-static]
if [ ! -f $ZLIB/lib/libz.a ]; then
echo
echo "### Building zlib ###"
echo
    curl -LO https://zlib.net/zlib-$ZLIB_VER.tar.gz
	tar -xzf zlib-$ZLIB_VER.tar.gz
    cd zlib-$ZLIB_VER
    ./configure --static --prefix=$ZLIB
    make -j$(nproc)
    make install
    cd ..
fi


# 2. Build lz4 from source (static) [alt Fedora packages are lz4-devel lz4-static]
if [ ! -f $LZ4/lib/liblz4.a ]; then
echo
echo " ### Building lz4 ###"
echo
    curl -LO https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VER.tar.gz
	tar -xzf v$LZ4_VER.tar.gz
    cd lz4-$LZ4_VER
    make liblz4.a -j$(nproc)
    mkdir -p $LZ4/lib $LZ4/include
    cp lib/liblz4.a $LZ4/lib/
    cp lib/*.h $LZ4/include/ 2>/dev/null || cp *.h $LZ4/include/
    cd ..
fi


# 3. Build zstd from source (static) [alt Fedora packages libzstd-static libzstd-devel]
if [ ! -f $ZSTD/lib/libzstd.a ]; then
echo
echo "### Building zstd ###"
echo
    curl -LO https://github.com/facebook/zstd/archive/refs/tags/v$ZSTD_VER.tar.gz
	tar -xzf v$ZSTD_VER.tar.gz
    cd zstd-$ZSTD_VER/lib
    make libzstd.a -j$(nproc)
    mkdir -p $ZSTD/lib $ZSTD/include
    cp libzstd.a $ZSTD/lib/
    cp *.h $ZSTD/include/
    [ -d common ] && cp -r common $ZSTD/include/
    cd ../..
fi


# 4. Build OpenSSL from source (static)
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


# 5. Build popt from source (static) [alt Fedora packages popt-devel popt-static]
if [ ! -f $POPT/lib/libpopt.a ]; then
echo
echo "### Building static popt ###"
echo
    curl -LO http://ftp.rpm.org/popt/releases/popt-1.x/popt-$POPT_VER.tar.gz
	tar -xzf popt-$POPT_VER.tar.gz
    cd popt-$POPT_VER
	./configure --prefix=$POPT --disable-shared --enable-static
	make -j$(nproc)
	make install
    cd ..
fi


# 6. Build xxHash from source (static) [alt Fedora packages xxhash-devel xxhash]

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


# 7. Build rsync from source (static)
echo
echo "### Building static rsync ###"
echo
	curl -LO https://github.com/RsyncProject/rsync/archive/refs/tags/v$RSYNC_VER.tar.gz
	tar -xzf v$RSYNC_VER.tar.gz
	cd rsync-$RSYNC_VER
	export PKG_CONFIG_PATH=$ZLIB/lib/pkgconfig:$OPENSSL/lib/pkgconfig:$POPT/lib/pkgconfig
	export CFLAGS="-I$ZLIB/include -I$LZ4/include -I$ZSTD/include -I$OPENSSL/include -I$POPT/include -I$XXHASH/include -std=c99 -O2"
	export LDFLAGS="-L$ZLIB/lib -L$LZ4/lib -L$ZSTD/lib -L$OPENSSL/lib -L$POPT/lib -L$XXHASH/lib -static -ldl -lpthread -lm"
	./configure --prefix=$RSYNC --disable-md2man --with-included-zlib=no
    make -j$(nproc)
    make install
	strip --strip-all $RSYNC/bin/rsync
    cd ..


# 8. Verify and report
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
