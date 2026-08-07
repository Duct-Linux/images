#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

mkdir -p $WORK_DIR
mkdir -p $CACHE_DIR
cp -r $SOURCE_DIR/rootfs $WORK_DIR
