#!/bin/sh

set -e

ROOT_DIR=$PWD
CONFIG=$ROOT_DIR/.config
SOURCE_DIR=$ROOT_DIR/src
WORK_DIR=$ROOT_DIR/work
CACHE_DIR=$ROOT_DIR/cache

ROOTFS=$WORK_DIR/rootfs

read_property() (
  prop_name=$1
  prop_value=

  if [ ! "$prop_name" = "" ]; then
    prop_value=$(grep -i ^${prop_name}= $CONFIG | cut -f2- -d'=' | xargs)
  fi

  echo $prop_value
)

download_source() (
  url=$1
  file=$2

  check_download_cache $url $file
  cp $CACHE_DIR/$file $WORK_DIR/$file
)

extract_source() (
  file=$1
  name=$2

  mkdir -p $WORK_DIR/$name

  tar -xvf $WORK_DIR/$file -C $WORK_DIR/$name
)

check_download_cache() {
  url=$1
  file=$2

  # check if cache exists
  if cat $CACHE_DIR/$file.url 2>/dev/null | grep -q $url; then
    echo "Using cached file: $file"
    return
  else
    echo "Downloading $file from $url"
    wget -O $CACHE_DIR/$file $url
    echo $url >$CACHE_DIR/$file.url
  fi
}

JOB_FACTOR=$(read_property JOB_FACTOR)
CFLAGS=$(read_property CFLAGS)
NUM_CORES=$(grep ^processor /proc/cpuinfo | wc -l)
NUM_JOBS=$((NUM_CORES * JOB_FACTOR))

# This one probably needs adjustments
TARGET=x86_64-duct-linux-gnu
