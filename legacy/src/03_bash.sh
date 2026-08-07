#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

# download
SOURCE_URL_BASH=$(read_property SOURCE_URL_BASH)
download_source $SOURCE_URL_BASH bash.tar.gz
extract_source bash.tar.gz bash

# env
BASH_SRC=$(ls -d $WORK_DIR/bash/bash-*)
BASH_BUILD=$WORK_DIR/bash-build

# prepare
mkdir -p $BASH_BUILD
cd $BASH_BUILD

# build
CFLAGS="$CFLAGS" $BASH_SRC/configure \
  --prefix=/usr \
  --without-bash-malloc
make -j $NUM_JOBS

# install
make install \
  DESTDIR=$ROOTFS

cd $ROOT_DIR
