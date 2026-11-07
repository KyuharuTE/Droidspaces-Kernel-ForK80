cmake_minimum_required(VERSION 3.22.1)
project(kpctl LANGUAGES C)

# KernelPatch's supercall is a single raw syscall (45). An ordinary app cannot
# be relied on to issue it, because app seccomp filters clamp down on which
# syscall numbers reach the kernel. Running as root through `su` bypasses the
# app profile, so this ships as a small CLI the app executes, not as a JNI
# library called in-process.
add_executable(kpctl kpctl.c)

target_compile_options(kpctl PRIVATE -Wall -Wextra -O2)

# Static: the binary is extracted from the APK and exec'd from app data, so it
# must not depend on a loader finding libc at a path that is not there. Android
# only allows exec of files it owns, which the extraction step handles.
target_link_options(kpctl PRIVATE -static)

# Install under a .so name so it is packaged uncompressed into lib/<abi>/ and
# can be extracted with the right permissions; Android blocks exec of files in
# read-only storage anyway, so the app copies it out first.
set_target_properties(kpctl PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libkpctl.so"
)
