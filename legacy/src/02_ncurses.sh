#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

# download
SOURCE_URL_NCURSES=$(read_property SOURCE_URL_NCURSES)
download_source $SOURCE_URL_NCURSES ncurses.tar.gz
extract_source ncurses.tar.gz ncurses

# env
NCURSES_SRC=$(ls -d $WORK_DIR/ncurses/ncurses-*)
NCURSES_BUILD=$WORK_DIR/ncurses-build

# prepare
mkdir -p $NCURSES_BUILD
cd $NCURSES_BUILD

# build
CFLAGS="$CFLAGS" $NCURSES_SRC/configure \
  --prefix=/usr \
  --with-termlib \
  --with-ticlib \
  --with-terminfo-dirs=/lib/terminfo \
  --with-default-terminfo-dirs=/lib/terminfo \
  --without-normal \
  --without-debug \
  --without-ada \
  --without-cxx-binding \
  --with-abi-version=6 \
  --enable-widec \
  --enable-pc-files \
  --with-shared \
  CPPFLAGS=-I$PWD/ncurses/widechar \
  LDFLAGS=-L$PWD/lib \
  CPPFLAGS="-P"
make -j $NUM_JOBS

# install
make install \
  DESTDIR=$ROOTFS

# postinstall
cd $ROOTFS

# symlink
cd usr/lib64
ln -s libncursesw.so.6 libncurses.so.6
ln -s libncurses.so.6 libncurses.so
ln -s libtinfow.so.6 libtinfo.so.6
ln -s libtinfo.so.6 libtinfo.so

cd $ROOT_DIR
