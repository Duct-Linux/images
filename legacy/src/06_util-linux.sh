#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

# download
SOURCE_URL_UTILLINUX=$(read_property SOURCE_URL_UTILLINUX)
download_source $SOURCE_URL_UTILLINUX util-linux.tar.gz
extract_source util-linux.tar.gz util-linux

# env
UTILLINUX_SRC=$(ls -d $WORK_DIR/util-linux/util-linux-*)
UTILLINUX_BUILD=$WORK_DIR/util-linux-build

# prepare
mkdir -p $UTILLINUX_BUILD
cd $UTILLINUX_BUILD

# build
$UTILLINUX_SRC/configure ADJTIME_PATH=/var/lib/hwclock/adjtime \
    --docdir=/usr/share/doc/util-linux-2.34 \
    --disable-chfn-chsh \
    --disable-login \
    --disable-nologin \
    --disable-su \
    --disable-setpriv \
    --disable-runuser \
    --disable-pylibmount \
    --disable-static \
    --without-python \
    --without-systemd \
    --without-systemdsystemunitdir
make -j $NUM_JOBS

# install
mkdir -pv $ROOT_DIR/var/lib/hwclock
# ToDo: fix this
#make install \
#    DESTDIR=$ROOTFS

# copy mount command
cp $UTILLINUX_BUILD/mount $ROOTFS/bin/

# clean
cd $ROOT_DIR
