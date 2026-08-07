#!/bin/bash

# working directory is /

set -e
. ./src/common.sh

./src/00_prepare.sh
./src/01_glibc.sh
./src/02_ncurses.sh
./src/03_bash.sh
# ./src/04_gcc.sh
./src/05_uutils.sh
./src/06_util-linux.sh
