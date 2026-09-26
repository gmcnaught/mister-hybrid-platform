# CMake cross toolchain for MiSTer armhf (Cortex-A9, NEON, hard-float, glibc 2.31).
#   cmake -DCMAKE_TOOLCHAIN_FILE=$MISTER_TOOLCHAIN_FILE ...
# NOTE: passing CMAKE_C_FLAGS on the command line REPLACES the *_INIT values
# below (solarus build_engine.sh hit this); append to MISTER_ARCH_FLAGS instead.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(triple arm-linux-gnueabihf)
set(CMAKE_C_COMPILER   ${triple}-gcc)
set(CMAKE_CXX_COMPILER ${triple}-g++)

# Multiarch sysroot: :armhf -dev packages live under /usr/lib/arm-linux-gnueabihf.
set(CMAKE_FIND_ROOT_PATH /usr/${triple} /usr/lib/${triple})
set(CMAKE_LIBRARY_ARCHITECTURE ${triple})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# Keep in sync with build/make/mister-flags.mk (tests/test_build_flags.sh checks).
# -mfpu=neon, NOT neon-vfpv4: the A9 has no VFPv4, and neon-vfpv4 code SIGILLs
# (donut patch 0002, frt_3.x arm32).
set(MISTER_ARCH_FLAGS "-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard")
set(CMAKE_C_FLAGS_INIT   "${MISTER_ARCH_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${MISTER_ARCH_FLAGS}")
