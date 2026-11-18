#!/bin/sh
set -eu
cd "$(dirname "$0")"
clang --target=aarch64-linux-android21 -std=c11 -Os \
  -ffreestanding -fno-builtin -fno-stack-protector -c \
  -o src/br77d.o src/br77d.c
python3 src/link.py src/br77d.o br77d
rm -f src/br77d.o
chmod 755 br77d
echo "built $(file br77d)"
