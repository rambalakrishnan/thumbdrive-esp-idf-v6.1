# ======================================================================================
# CHANGELOG
# --------------------------------------------------------------------------------------
# [n16r8-16mb-flash] 2026-08-19  s.ram.balakrishnan@gmail.com
#   - This is the root CMakeLists.txt for the usb_thumbdrive project.
#   - Target: ESP32-S3 N16R8 (16 MB flash, 8 MB PSRAM, internal USB PHY).
#   - ESP-IDF version: v6.1-beta1.
#   - Project name: usb_thumbdrive (used as the firmware image name).
#   - No changes needed for the 16MB config round — this file was already
#     correct from the initial project structure commit.
# ======================================================================================
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(usb_thumbdrive)
