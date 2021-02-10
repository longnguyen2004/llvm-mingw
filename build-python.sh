#!/bin/sh
#
# Copyright (c) 2018 Martin Storsjo
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e

: ${LIBFFI_VERSION:=v3.3}
: ${PYTHON_MAJOR:=3}
: ${PYTHON_MINOR:=8}
: ${PYTHON_PATCH:=7}
: ${PYTHON_VERSION:=v${PYTHON_MAJOR}.${PYTHON_MINOR}.${PYTHON_PATCH}}
: ${MINGW_W64_PATCH_VERSION:=14ad4c740093181f5b89a368f6f572a96caeab36}

unset HOST

while [ $# -gt 0 ]; do
    case "$1" in
    --host=*)
        HOST="${1#*=}"
        ;;
    *)
        PREFIX="$1"
        ;;
    esac
    shift
done

if [ -z "$CHECKOUT_ONLY" ]; then
    if [ -z "$PREFIX" ]; then
        echo $0 --host=<triple> dest
        exit 1
    fi

    mkdir -p "$PREFIX"
    PREFIX="$(cd "$PREFIX" && pwd)"
fi

# Fetching
if [ ! -d libffi ]; then
    git clone https://github.com/libffi/libffi.git
    CHECKOUT_LIBFFI=1
fi

if [ ! -d cpython ]; then
    git clone https://github.com/python/cpython.git
    CHECKOUT_PYTHON=1
fi

if [ ! -d MINGW-packages ]; then
    git clone https://github.com/msys2/MINGW-packages.git
    CHECKOUT_PATCHES=1
fi

if [ -n "$SYNC" ] || [ -n "$CHECKOUT_LIBFFI" ]; then
    cd libffi
    [ -z "$SYNC" ] || git fetch
    git checkout $LIBFFI_VERSION
    git cherry-pick c06468f
    git cherry-pick 15d3ea3
    autoreconf -vfi
    cd ..
fi

if [ -n "$SYNC" ] || [ -n "$CHECKOUT_PATCHES" ]; then
    cd MINGW-packages
    [ -z "$SYNC" ] || git fetch
    git checkout $MINGW_W64_PATCH_VERSION
    cd ..
fi

if [ -n "$SYNC" ] || [ -n "$CHECKOUT_PYTHON" ]; then
    cd cpython
    [ -z "$SYNC" ] || git fetch
    # Revert our patches
    git reset --hard HEAD
    git clean -fx
    git checkout $PYTHON_VERSION
    cat ../MINGW-packages/mingw-w64-python/*.patch | patch -Nup1
    cat ../patches/python/*.patch | patch -Nup1
    autoreconf -vfi
    cd ..
fi

[ -z "$CHECKOUT_ONLY" ] || exit 0

MAKE=make
if [ -n "$(which gmake)" ]; then
    MAKE=gmake
fi

: ${CORES:=$(nproc 2>/dev/null)}
: ${CORES:=$(sysctl -n hw.ncpu 2>/dev/null)}
: ${CORES:=4}

cd libffi
[ -z "$CLEAN" ] || rm -rf build-$HOST
mkdir -p build-$HOST
cd build-$HOST
../configure --prefix="$PREFIX" --host=$HOST --disable-symvers --disable-docs
$MAKE -j$CORES
$MAKE install
cd ../..

cd cpython
rm -f PC/pyconfig.h
[ -z "$CLEAN" ] || rm -rf build-$HOST
mkdir -p build-$HOST
cd build-$HOST
BUILD=$(../config.guess) # Python configure requires build triplet for cross compilation

export ac_cv_working_tzset=no
export ac_cv_header_dlfcn_h=no
export ac_cv_lib_dl_dlopen=no
export ac_cv_have_decl_RTLD_GLOBAL=no
export ac_cv_have_decl_RTLD_LAZY=no
export ac_cv_have_decl_RTLD_LOCAL=no
export ac_cv_have_decl_RTLD_NOW=no
export ac_cv_have_decl_RTLD_DEEPBIND=no
export ac_cv_have_decl_RTLD_MEMBER=no
export ac_cv_have_decl_RTLD_NODELETE=no
export ac_cv_have_decl_RTLD_NOLOAD=no

# Avoid gcc workarounds in distutils
export CC=$HOST-clang
export CXX=$HOST-clang++

../configure --prefix="$PREFIX" --build=$BUILD --host=$HOST \
    CFLAGS=" -fwrapv -D__USE_MINGW_ANSI_STDIO=1 -D_WIN32_WINNT=0x0601 -DNDEBUG -I../PC -I$PREFIX/include -Wno-ignored-attributes" \
    CXXFLAGS=" -fwrapv -D__USE_MINGW_ANSI_STDIO=1 -D_WIN32_WINNT=0x0601 -DNDEBUG -I../PC -I$PREFIX/include -Wno-ignored-attributes" \
    LDFLAGS="-L$PREFIX/lib" \
    --enable-shared --with-nt-threads --with-system-ffi --without-ensurepip --without-c-locale-coercion
# $MAKE regen-importlib
# Omitting because it requires building a native Python, which gets complicated depending on what system we're building on
$MAKE -j$CORES
$MAKE install
cp libpython${PYTHON_MAJOR}.${PYTHON_MINOR}.dll.a "$PREFIX/lib"
cd ../..
