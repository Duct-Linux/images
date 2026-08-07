#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

# download
SOURCE_URL_GLIBC=$(read_property SOURCE_URL_GLIBC)
download_source $SOURCE_URL_GLIBC glibc.tar.gz
extract_source glibc.tar.gz glibc

# env
GLIBC_SRC=$(ls -d $WORK_DIR/glibc/glibc-*)
GLIBC_BUILD=$WORK_DIR/glibc-build

# prepare
mkdir -p $GLIBC_BUILD
cd $GLIBC_BUILD

# build
CFLAGS="$CFLAGS" $GLIBC_SRC/configure \
  --prefix=/usr \
  --without-gd \
  --without-selinux \
  --disable-werror
make -j $NUM_JOBS

# install
make install \
  DESTDIR=$ROOTFS

cd $ROOT_DIR
