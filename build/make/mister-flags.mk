# Make fragment: MiSTer armhf cross flags. include $(MISTER_PLATFORM)/build/make/mister-flags.mk
# Keep in sync with build/cmake/arm-linux-gnueabihf.toolchain.cmake.
MISTER_TRIPLE     ?= arm-linux-gnueabihf
MISTER_CC         ?= $(MISTER_TRIPLE)-gcc
MISTER_CXX        ?= $(MISTER_TRIPLE)-g++
# -mfpu=neon, NOT neon-vfpv4 (SIGILL on the A9; donut patch 0002).
MISTER_ARCH_FLAGS := -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard
# Include path for spec/generated (mister_map_<profile>.h, mister_profiles.h).
MISTER_SPEC_INC   := $(dir $(lastword $(MAKEFILE_LIST)))../../spec/generated
