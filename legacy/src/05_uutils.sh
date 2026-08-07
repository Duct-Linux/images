#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

# download
BINARY_URL_UUTILS=$(read_property BINARY_URL_UUTILS)
download_source $BINARY_URL_UUTILS uutils.tar.gz
extract_source uutils.tar.gz uutils

# env
UUTILS_SRC=$(ls -d $WORK_DIR/uutils/coreutils-*)

# install
cp $UUTILS_SRC/coreutils $ROOTFS/bin/

# symlink
cd $ROOTFS/bin
# ToDo: fix this
ln -s coreutils ls
ln -s coreutils cat
ln -s coreutils chmod
ln -s coreutils chown
ln -s coreutils cp

# This is a hack to make it work
cp /lib/libgcc_s.so.1 $ROOTFS/lib/
cp /lib64/libgcc_s.so.1 $ROOTFS/lib64/

# clean
cd $ROOT_DIR
