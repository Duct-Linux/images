#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

# download
SOURCE_URL_GCC=$(read_property SOURCE_URL_GCC)
download_source $SOURCE_URL_GCC gcc.tar.gz
extract_source gcc.tar.gz gcc
SOURCE_URL_MPFR=$(read_property SOURCE_URL_MPFR)
download_source $SOURCE_URL_MPFR mpfr.tar.gz
extract_source mpfr.tar.gz gcc
SOURCE_URL_GMP=$(read_property SOURCE_URL_GMP)
download_source $SOURCE_URL_GMP gmp.tar.xz
extract_source gmp.tar.xz gcc
SOURCE_URL_MPC=$(read_property SOURCE_URL_MPC)
download_source $SOURCE_URL_MPC mpc.tar.gz
extract_source mpc.tar.gz gcc

# env
GCC_SRC=$(ls -d $WORK_DIR/gcc/gcc-*)
GCC_BUILD=$WORK_DIR/gcc-build/gcc
GMP_SRC=$(ls -d $WORK_DIR/gcc/gmp-*)
GMP_BUILD=$WORK_DIR/gcc-build/gmp
MPFR_SRC=$(ls -d $WORK_DIR/gcc/mpfr-*)
MPFR_BUILD=$WORK_DIR/gcc-build/mpfr
MPC_SRC=$(ls -d $WORK_DIR/gcc/mpc-*)
MPC_BUILD=$WORK_DIR/gcc-build/mpc

# prepare
mkdir -p $GCC_BUILD
mkdir -p $GMP_BUILD
mkdir -p $MPFR_BUILD
mkdir -p $MPC_BUILD

# build
cd $GMP_BUILD
CFLAGS="$CFLAGS" $GMP_SRC/configure --disable-shared --enable-static --prefix=/usr
make
make install \
    DESTDIR=$ROOTFS

cd $MPFR_BUILD
CFLAGS="$CFLAGS" $MPFR_SRC/configure --disable-shared --enable-static --prefix=/usr --with-gmp=$ROOTFS/usr
make
make install \
    DESTDIR=$ROOTFS

cd $MPC_BUILD
CFLAGS="$CFLAGS" $MPC_SRC/configure --disable-shared --enable-static --prefix=/usr --with-gmp=$ROOTFS/usr --with-mpfr=$ROOTFS/usr
make
make install \
    DESTDIR=$ROOTFS

cd $GCC_BUILD
CFLAGS="$CFLAGS" $GCC_SRC/configure \
    --prefix=/usr \
    --with-build-sysroot=$ROOTFS \
    LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc \
    --without-headers \
    --enable-default-pie \
    --enable-default-ssp \
    --disable-nls \
    --disable-multilib \
    --disable-libatomic \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libvtv \
    --with-gmp=$ROOTFS/usr \
    --with-mpfr=$ROOTFS/usr \
    --with-mpc=$ROOTFS/usr \
    --enable-languages=c,c++
make -j $NUM_JOBS

# install
make install \
    DESTDIR=$ROOTFS

cd $ROOT_DIR
