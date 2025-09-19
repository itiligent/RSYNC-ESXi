#!/bin/bash
###############################################################################################################
# Compile a static RSYNC binary (ALL FROM SOURCE) for use with VMware ESXi (6,7,8 & 9 )
# David Harrop
# September 2025
###############################################################################################################

## Build Instructions
# 1. This script is tested on Debian 13, Ubuntu 24, Fedora 42 & RHEL 9 / 10. It should work with most Redhat flavored distros
# 	 that support glibc-static. For a full RedHat flavoured list see here: https://pkgs.org/download/glibc-static.
#    Where a glibc-static istro package is available, this script will build a custom glibc-static package
#
# 2. Run the build script NOT as sudo or root ./rsync-esxi-builder-multiOS.sh
#
# 3. When the script completes, copy the compiled rsync binary from $HOME/build-static/bin to
#    all source & destination ESXi hosts** (note the install path of each - you will need this later)
#
# 4. On each ESXi host, set execute permissions on the binary: chmod 755 /path/to/rsync
#
# 5. For ESXi 8 and above only – you must also allow execution of non-native binaries:
#    esxcli system settings advanced set -o /User/execInstalledOnly -i 0
#
# 6. Configure RSA SSH keys for passwordless SSH authentication. Note: VMware does not currently support Ed25519
#    keys for Esxi host to host sessions.)
#
# 7. Look to https://github.com/itiligent/RSYNC-ESXi/blob/main/rsync-host-2-host.sh for the companion replication script
#
# 8. Common issues:
#    - Using a version of glibc that is too far ahead of your base distro can cause build failures.
#    - On some older distros, OpenSSL may cause issues during the build.
#        - If you cannot build on the latest distro, you can disable OpenSSL in the rsync build.
#          (For ESXi builds, OpenSSL is not really needed anyway.)

set -eu

clear

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
NC="\033[0m" # No colour

echo
echo -e "${CYAN}### Rsync for ESXi build script ###${NC}"
echo

if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}Error: This script should NOT be run as root or with sudo.${NC}"
    exit 1
fi

RSYNC_VER="3.4.1"
ZLIB_VER="1.3.1"
LZ4_VER="1.10.0"
ZSTD_VER="1.5.7"
POPT_VER="1.19"
XXHASH_VER="0.8.3"
GLIBC_VER="2.39"    # Only for RedHat distros without glibc-static. Match by age according to your distro — don’t use bleeding edge. For CentOS/RHEL 9–10, use glibc 2.39.
OPENSSL_VER="1.1.1w" # Must use OpenSSL 1.1.1 (legacy) product track due to rsync's md5 dependencies
ENABLE_OPENSSL=true  # true | false - For crypto issues during build, change OS or set to false

WORKDIR="$HOME/build-static"
PREFIX="$WORKDIR/prefix"
ZLIB="$WORKDIR/zlib"
LZ4="$WORKDIR/lz4"
ZSTD="$WORKDIR/zstd"
OPENSSL="$WORKDIR/openssl"
POPT="$WORKDIR/popt"
RSYNC="$WORKDIR/rsync"
XXHASH="$WORKDIR/xxhash"

mkdir -p "$WORKDIR" "$PREFIX" "$ZLIB" "$LZ4" "$ZSTD" "$OPENSSL" "$POPT" "$RSYNC" "$XXHASH"
cd "$WORKDIR"

# Function to install dependencies on RedHat systems
install_redhat() {
    echo -e "${CYAN}Detected RedHat-based system. Installing dependencies...${NC}"
    echo

    # Detect package manager
    if command -v yum >/dev/null 2>&1; then
        PM="yum"
        sudo yum -y update
        sudo yum -y install curl automake perl gcc pkg-config
    elif command -v dnf >/dev/null 2>&1; then
        PM="dnf"
        sudo dnf -y upgrade
        sudo dnf -y install curl automake perl gcc pkg-config
    fi

    echo
    echo -e "${CYAN}Checking if glibc-static is available in repos...${NC}"
    if sudo $PM list available glibc-static >/dev/null 2>&1; then
        echo -e "${GREEN}glibc-static package found in repo. Installing...${NC}"
        sudo $PM -y install glibc-static
        GLIBC_CFLAGS=""
        GLIBC_LDFLAGS=""
        return
    else
        echo -e "${YELLOW}glibc-static not available in repo. Building from source...${NC}"
        echo
        sudo $PM -y install make rpm-build zlib-devel bison
    fi

    # To build on Redhat systems without glibc-static packages, we must build our own glibc-static rpm
    GLIBC="$WORKDIR/glibc"
    mkdir -p "$GLIBC"
    mkdir -p "$HOME/rpmbuild"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

    GLIBC_CFLAGS="-I$GLIBC/include"
    GLIBC_LDFLAGS="-L$GLIBC/lib"
    GLIBC_SPEC_FILE="$HOME/rpmbuild/SPECS/glibc-$GLIBC_VER-static.spec"
    GLIBC_DEST="$HOME/rpmbuild/SOURCES/glibc-$GLIBC_VER.tar.gz"
	
	echo
    echo -e "${CYAN}Downloading glibc source to $HOME/rpmbuild/SOURCES, this may be slow...${NC}"
    echo
	echo "Checking if glibc source is already present in $HOME/rpmbuild/SOURCES..."
   # Check if file exists and is a valid gzip tarball
    if [ -s "$GLIBC_DEST" ] && file "$GLIBC_DEST" | grep -q "gzip compressed data"; then
      echo "File $GLIBC_DEST already exists and looks valid. Skipping download."
    else
      echo "Downloading glibc source, this may take a while..."
      curl -L -o "$GLIBC_DEST" "https://ftpmirror.gnu.org/glibc/glibc-$GLIBC_VER.tar.gz"

    # Verify download
    if [ ! -s "$GLIBC_DEST" ]; then
        echo "Download failed: file is empty."
        exit 1
    fi

    file "$GLIBC_DEST" | grep -q "gzip compressed data" || {
        echo "Download is not a valid tar.gz file."
        echo "For download issues, try manually downloading glibc-$GLIBC_VER.tar.gz"
        echo "and copy to $HOME/rpmbuild/SOURCES/ before re-running this script."
        exit 1
    }
    echo "Download complete and verified."
fi

    cat >"$GLIBC_SPEC_FILE" <<EOF
# Default version and prefix, can be overridden with --define
%{!?glibc_ver:%global glibc_ver $GLIBC_VER }
%{!?install_prefix:%global install_prefix /usr/local/glibc-static }

# Avoid creating debug subpackages (this is a static-only package)
%define debug_package %{nil}

# Disable strip of static archives (glibc uses scripts and special ELF in .a files)
%global __brp_strip_static_archive %{nil}
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_lto %{nil}

# Ensure we don't treat warnings as errors by default
%global optflags -O2 -Wno-error

Name:           glibc-static
Version:        %{glibc_ver}
Release:        1%{?dist}
Summary:        Static glibc %{version} libraries (minimal)
License:        LGPL-2.1-or-later
URL:            https://www.gnu.org/software/libc/
Source0:        https://ftp.gnu.org/gnu/glibc/glibc-%{glibc_ver}.tar.gz
BuildRequires:  rpm-build, gcc, make, bison

%description
Static-only build of glibc (%{version}), packaged with just headers and
static libraries for linking fully static binaries.

%prep
%setup -q -n glibc-%{version}

%build
mkdir -p build
cd build
../configure --prefix=%{install_prefix} --disable-multilib
make %{?_smp_mflags}

%install
rm -rf %{buildroot}
cd build
make install DESTDIR=%{buildroot}

# Remove everything except static libs and headers
find %{buildroot}%{install_prefix}/lib -type f ! -name "*.a" -delete
rm -rf %{buildroot}%{install_prefix}/share
rm -rf %{buildroot}%{install_prefix}/bin
rm -rf %{buildroot}%{install_prefix}/sbin
rm -rf %{buildroot}%{install_prefix}/etc
rm -rf %{buildroot}%{install_prefix}/var
rm -rf %{buildroot}%{install_prefix}/libexec
rm -rf %{buildroot}%{install_prefix}/include/gnu/lib-names.h
rm -rf %{buildroot}%{install_prefix}/lib/*.so*

%files
%{?install_prefix}/lib*/lib*.a
%{install_prefix}/include/*

%changelog
* Fri Sep 19 2025 Created by Itiligent - %{glibc_ver}-1
- Minimal static glibc build: headers + static libs only
EOF

    cd /
    # Bake the $GLIB_VER user prefix into the rpm to keep our build away from the system's glibc files
    rpmbuild -ba "$GLIBC_SPEC_FILE" --define "glibc_ver $GLIBC_VER" --define "install_prefix $GLIBC"
    rpm2cpio "$HOME/rpmbuild/RPMS/x86_64/glibc-static-$GLIBC_VER"*.rpm | cpio -idmv
}

# Function to install dependencies on Debian-based systems
install_debian() {
    echo -e "${CYAN}Detected Debian-based system. Installing dependencies...${NC}"
    echo
    sudo apt update
    sudo apt -y install curl build-essential automake libssl-dev pkg-config

    # Use the default Debian system glibc static libraries
    GLIBC_CFLAGS=""
    GLIBC_LDFLAGS=""
}

# Detect the package manager and install dependencies accordingly
if command -v yum >/dev/null 2>&1; then
    install_redhat
elif command -v dnf >/dev/null 2>&1; then
    install_redhat
elif command -v apt >/dev/null 2>&1; then
    install_debian
else
    echo -e "${RED}Unsupported system. Please install dependencies manually.${NC}"
    exit 1
fi

cd "$WORKDIR"

echo -e "${GREEN}All dependencies installed successfully!${NC}"
echo

# 1. Build zlib
if [ ! -f "$ZLIB/lib/libz.a" ]; then
    echo
    echo -e "${CYAN}### Building zlib ###${NC}"
    echo
    curl -LO "https://github.com/madler/zlib/archive/refs/tags/v$ZLIB_VER.tar.gz"
    tar -xzf "v$ZLIB_VER.tar.gz"
    cd "zlib-$ZLIB_VER"
    ./configure --static --prefix="$ZLIB"
    make -j"$(nproc)"
    make install
    cd ..
fi

# 2. Build lz4
if [ ! -f "$LZ4/lib/liblz4.a" ]; then
    echo
    echo -e "${CYAN}### Building static lz4 ###${NC}"
    echo
    curl -LO "https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VER.tar.gz"
    tar -xzf "v$LZ4_VER.tar.gz"
    cd "lz4-$LZ4_VER"
    make liblz4.a -j"$(nproc)"
    mkdir -p "$LZ4/lib" "$LZ4/include"
    cp lib/liblz4.a "$LZ4/lib/"
    cp lib/*.h "$LZ4/include/" 2>/dev/null || cp *.h "$LZ4/include/"
    cd ..
fi

# 3. Build zstd
if [ ! -f "$ZSTD/lib/libzstd.a" ]; then
    echo
    echo -e "${CYAN}### Building static zstd ###${NC}"
    echo
    curl -LO "https://github.com/facebook/zstd/archive/refs/tags/v$ZSTD_VER.tar.gz"
    tar -xzf "v$ZSTD_VER.tar.gz"
    cd "zstd-$ZSTD_VER/lib"
    make libzstd.a -j"$(nproc)"
    mkdir -p "$ZSTD/lib" "$ZSTD/include"
    cp libzstd.a "$ZSTD/lib/"
    cp *.h "$ZSTD/include/"
    [ -d common ] && cp -r common "$ZSTD/include/"
    cd ../..
fi

# 4. Build popt
if [ ! -f "$POPT/lib/libpopt.a" ]; then
    echo
    echo -e "${CYAN}### Building popt ###${NC}"
    echo
    curl -LO "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-$POPT_VER.tar.gz"
    tar -xzf "popt-$POPT_VER.tar.gz"
    cd "popt-$POPT_VER"
    ./configure --prefix="$POPT" --disable-shared --enable-static
    make -j"$(nproc)"
    make install
    cd ..
fi

# 5. Build xxHash
if [ ! -f "$XXHASH/lib/libxxhash.a" ]; then
    echo
    echo -e "${CYAN}### Building static xxHash ###${NC}"
    echo
    curl -LO "https://github.com/Cyan4973/xxHash/archive/refs/tags/v$XXHASH_VER.tar.gz"
    tar -xzf "v$XXHASH_VER.tar.gz"
    cd "xxHash-$XXHASH_VER"
    mkdir -p "$XXHASH/lib" "$XXHASH/include"
    make -j"$(nproc)"
    cp libxxhash.* "$XXHASH/lib/"
    cp *.h "$XXHASH/include/"
    cd ..
fi

# 6. Build OpenSSL
if [ "$ENABLE_OPENSSL" = true ]; then
    echo
    echo -e "${GREEN}Adding OpenSSL support...${NC}"
    OPENSSL_OPT="--with-openssl"
    CFLAGS_OPENSSL="-I$OPENSSL/include"
    LDFLAGS_OPENSSL="-L$OPENSSL/lib"
    if [ ! -f "$OPENSSL/lib/libssl.a" ]; then
        echo
        echo -e "${CYAN}### Building static openssl (to suit ESXi shell) ###${NC}"
        echo
        curl -LO "https://www.openssl.org/source/openssl-$OPENSSL_VER.tar.gz"
        tar -xzf "openssl-$OPENSSL_VER.tar.gz"
        cd "openssl-$OPENSSL_VER"
        ./Configure linux-x86_64 no-shared no-dso no-async \
            no-comp no-hw no-tests no-afalgeng -DOPENSSL_NO_SECURE_MEMORY --prefix="$OPENSSL"
        make -j"$(nproc)"
        make install_sw
        cd ..
    fi
else
    echo
    echo -e "${YELLOW}Building rsync WITHOUT OpenSSL support...${NC}"
    echo
    OPENSSL_OPT="--disable-openssl"
    CFLAGS_OPENSSL=""
    LDFLAGS_OPENSSL=""
fi

# 7. Build rsync
echo
echo -e "${CYAN}### Building static rsync ###${NC}"
echo
curl -LO "https://github.com/RsyncProject/rsync/archive/refs/tags/v$RSYNC_VER.tar.gz"
tar -xzf "v$RSYNC_VER.tar.gz"
cd "rsync-$RSYNC_VER"
    PKG_CONFIG_PATH="$ZLIB/lib/pkgconfig:$POPT/lib/pkgconfig:$OPENSSL/lib/pkgconfig" \
    CFLAGS="-I$XXHASH/include -I$ZLIB/include -I$LZ4/include -I$ZSTD/include -I$POPT/include $CFLAGS_OPENSSL $GLIBC_CFLAGS -std=c99 -O2" \
    LDFLAGS="-static -L$ZLIB/lib -L$LZ4/lib -L$ZSTD/lib -L$POPT/lib -L$XXHASH/lib $LDFLAGS_OPENSSL $GLIBC_LDFLAGS -ldl -lm -lpthread" \
    ./configure --prefix="$RSYNC" --disable-md2man --with-included-zlib=no $OPENSSL_OPT

    CFLAGS="-I$XXHASH/include -I$ZLIB/include -I$LZ4/include -I$ZSTD/include -I$POPT/include $CFLAGS_OPENSSL $GLIBC_CFLAGS -std=c99 -O2" \
    LDFLAGS="-static -L$ZLIB/lib -L$LZ4/lib -L$ZSTD/lib -L$POPT/lib -L$XXHASH/lib $LDFLAGS_OPENSSL $GLIBC_LDFLAGS -ldl -lm -lpthread" \
    make -j"$(nproc)"

    make install
    strip --strip-all "$RSYNC/bin/rsync"
cd ..

# 8. Verify and report
RSYNC_BIN="$RSYNC/bin/rsync"

echo
echo -e "${GREEN}Static rsync build complete!${NC}"
echo

FILE_INFO="$(file "$RSYNC_BIN")"
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
