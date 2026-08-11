# LMA

A collection of programs with the objective of running the full pipeline for processing and analysing the data from a lightning mapping array (LMA).

## Table of Contents
1. [Build Process](#Build-Process)
    1. [Requirements](#Requirements)
    2. [Compiling](#Compiling)

2. [Running](#Running)
    1. [Signal Matching](#Signal-Matching)
    2. [Hole Detection](#Hole-Detection)


## Build Process

### Requirements

Zig compiler version 0.16.0 (the version can be seen using `zig version`)

### Compiling

To compile all programs, run the following command:

```
zig build -Doptimize=ReleaseSafe
```

This will generate an executable for the host system and CPU. The executable can be found at `zig-out/bin`.

If the objective is to run the program in other systems, this can be specified with both `-Dtarget=arch-OS-ABI` and `-Dcpu=model+features`. Some examples:

```
# Build for a linux x86_64 without any restrictions on the cpu
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-none

# Build for a mac with an m3 or newer
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos-none -Dcpu=apple_m3

# Build for a 32-bit windows machin running on a pentium 3
zig build -Doptimize=ReleaseSafe -Dtarget=x86-windows-none -Dcpu=pentium3
```

## Running

### Signal Matching

Example:

```
match \
  --date 25/11/06 --time 06:50:00 --analyse 10:00 \
  --stations stations/upc.gps stations/mcat.gps \
  --input signals/251106/*_251106_065000.dat \
  --output-path out/
```

You can view the full CLI information by running `match --help`.

### Hole Detection

Still in development, it may break at any time.

You can view the full CLI information by running `holes --help`.
