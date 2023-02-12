#!/bin/bash

mkdir -p releases
rm -rf zig-out
zig build -Dtarget=$1
tar -cvzf releases/dstr-$1.tar.gz -C zig-out/bin/ dstr


