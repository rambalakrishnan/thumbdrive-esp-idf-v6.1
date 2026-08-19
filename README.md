# ESP32-S3 USB MSC Thumbdrive (ESP-IDF v6.1-beta1)

A USB mass storage device firmware for the **ESP32-S3 N16R8** module that
presents raw flash storage to a host computer as a USB Mass Storage Class (MSC)
device with **512-byte logical sectors** — suitable for booting a **Bay Trail
NUC with 32-bit UEFI**.

Built with **ESP-IDF v6.1-beta1** and **Espressif's esp_tinyusb v2.2.1**
component.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Hardware Requirements](#2-hardware-requirements)
3. [Software Setup](#3-software-setup)
4. [Building](#4-building)
5. [Flashing](#5-flashing)
6. [Creating a Bootable USB Drive](#6-creating-a-bootable-usb-drive)
7. [Testing](#7-testing)
8. [Partition Table](#8-partition-table)
9. [How It Works](#9-how-it-works)
10. [Project Structure](#10-project-structure)
11. [Troubleshooting](#11-troubleshooting)
12. [License](#12-license)

---

## 1. Overview

This firmware turns an ESP32-S3 N16R8 module into a USB flash drive that
appears to any host computer as a standard mass storage device. The key
design decisions are:

| Feature | Value | Rationale |
|---|---|---|
| **Sector size** | 512 bytes | UEFI requires 512-byte sectors for boot devices |
| **Mount mode** | `MOUNT_USB` (raw) | Exposes raw sectors via wear-levelling — no FAT mount on the device side |
| **File system** | None (host-side MBR+FAT32) | The host creates the partition table and filesystem using standard Linux tools |
| **Flash size** | 16 MB | N16R8 module specification |
| **USB speed** | Full-Speed (12 Mbps) | ESP32-S3 internal USB PHY limitation |

### Boot Flow

1. ESP32-S3 boots from internal ROM
2. Second-stage bootloader initializes
3. Application mounts the `storage` partition through the wear-levelling layer
4. TinyUSB MSC enumerates as a USB mass storage device with 512-byte sectors
5. Host sees a raw ~15.75 MB block device
6. Host creates MBR + FAT32 partition using `fdisk` + `mkfs.fat`
7. Host copies UEFI bootloader (`BOOTIA32.EFI`), kernel, and initramfs
8. Bay Trail NUC boots from the USB device via 32-bit UEFI

---

## 2. Hardware Requirements

### Supported Hardware

| Component | Model | Notes |
|---|---|---|
| **Microcontroller** | ESP32-S3 N16R8 | 16 MB flash, 8 MB PSRAM, internal USB PHY |
| **USB Cable** | USB-C to USB-A (or USB-C to USB-C) | Must be a **data cable** — charge-only cables will not work |
| **Flash Tool** | Any USB-to-UART adapter | CP210x, CH340, FT232, or built-in USB-Serial on dev kit |

### Target Use Case

- **Computer**: Intel Bay Trail NUC (or any PC with 32-bit UEFI)
- **Boot mode**: UEFI (CSM/Legacy disabled)
- **EFI file**: `\EFI\BOOT\BOOTIA32.EFI` (32-bit UEFI bootloader)

---

## 3. Software Setup

### Prerequisites

```bash
# ESP-IDF v6.1-beta1 at ~/workspace/esp
# If not already installed, follow Espressif's official guide:
# https://docs.espressif.com/projects/esp-idf/en/v6.1-beta1/esp32s3/get-started/linux-macos/setup.html

# Verify installation
source ~/workspace/esp/export.sh
idf.py --version
# Expected: ESP-IDF v6.1-beta1

# Verify toolchain
xtensa-esp32s3-elf-gcc --version
# Expected: xtensa-esp32s3-elf-gcc (Espressif 15.2.0) 15.2.0
```

### Python Environment

```bash
# ESP-IDF creates a Python virtual environment during setup
~/.espressif/python_env/idf6.1_py3.14_env/
# Activate with: source ~/workspace/esp/export.sh
```

---

## 4. Building

### Quick Build

```bash
cd ~/workspace/thumbdrive
source ~/workspace/esp/export.sh

# Clean build (removes cached config + artifacts)
idf.py clean
rm -f sdkconfig          # Remove stale config so defaults are regenerated
idf.py reconfigure       # Generate new sdkconfig from sdkconfig.defaults
idf.py build             # Compile and link
```

### Expected Output

```
usb_thumbdrive.bin binary size 0x2fc10 bytes.
Project build complete. To flash, run:
 idf.py -p /dev/ttyUSB0 flash
```

- **Binary size**: 195,088 bytes (195 KB) — fits in the 192 KB factory partition with 1,008 bytes to spare
- **Flash size**: 16 MB (`--flash-size 16MB`)
- **Partition table**: Custom (`partitions.csv`) with factory @ 0x10000, storage @ 0x40000

### Build Configuration Files

| File | Purpose |
|---|---|
| `sdkconfig.defaults` | Default config settings (target, flash size, sector size, MSC enabled) |
| `partitions.csv` | Custom partition table (NVS, PHY, Factory, Storage) |
| `main/idf_component.yml` | Component dependencies (`espressif/esp_tinyusb: ^2.2.1`) |
| `CMakeLists.txt` | Root CMake project definition |
| `main/CMakeLists.txt` | Component registration for the `main` component |

---

## 5. Flashing

### Option A: ESP-IDF Command Line

```bash
cd ~/workspace/thumbdrive
source ~/workspace/esp/export.sh

# Connect ESP32-S3 in download mode (hold BOOT, press RST, release BOOT)
idf.py -p /dev/ttyUSB0 -b 460800 flash
```

This flashes three binaries at their offsets:
- `0x00000` — bootloader (14 KB)
- `0x08000` — partition table (3 KB)
- `0x10000` — application firmware (195 KB)

### Option B: esptool.py (Combined Binary)

```bash
# Flash the pre-merged binary (available on GitHub Releases)
python -m esptool --chip esp32s3 \
  --before default-reset \
  --after hard-reset \
  write-flash \
  --flash-mode dio \
  --flash-freq 80m \
  --flash-size 16MB \
  0x0 combined.bin
```

The `combined.bin` (256 KB) is available as a [GitHub Release asset](https://github.com/rambalakrishnan/thumbdrive-esp-idf-v6.1/releases/tag/v0.1.0).

MD5: `95b89cc83c96cd65c63626a12bc9fcd3`

### Option C: WebSerial (web.esphome.io)

1. Download `combined.bin` to your laptop
2. Open [web.esphome.io](https://web.esphome.io) in Chrome/Edge
3. Click **"Connect"** — select your USB-to-UART adapter
4. Put ESP32-S3 in download mode (hold BOOT, press RST, release BOOT)
5. Set **Upload mode** to **"Flash at 0x0"**
6. Select `combined.bin` → Click **"Install"**

---

## 6. Creating a Bootable USB Drive

After flashing, the ESP32-S3 will enumerate as a raw USB mass storage device
with no filesystem. You need to create the MBR, partition, and FAT32 filesystem:

```bash
# 1. Verify the device is detected with 512-byte sectors
lsblk -o NAME,SIZE,LOG-SEC,RM
# Should show a ~15.75 MB device with LOG-SEC=512

# 2. Create MBR partition table
sudo fdisk /dev/sdX

#   In fdisk:
#   o          (new empty DOS partition table)
#   n          (new partition)
#   <Enter>   (default partition number)
#   <Enter>   (default first sector)
#   <Enter>   (default last sector — uses full device)
#   t          (change partition type)
#   0c         (Windows 95 FAT32 LBA)
#   w          (write changes and exit)

# 3. Format as FAT32
sudo mkfs.fat -F32 -n BOOT /dev/sdX1

# 4. Mount and copy UEFI boot files
sudo mkdir -p /mnt/esp32boot
sudo mount /dev/sdX1 /mnt/esp32boot

# Create EFI directory structure
sudo mkdir -p /mnt/esp32boot/EFI/BOOT

# Copy your 32-bit UEFI bootloader
#   This file must be named BOOTIA32.EFI
sudo cp BOOTIA32.EFI /mnt/esp32boot/EFI/BOOT/

# Copy your kernel (vmlinuz) and initramfs (initramfs.img)
sudo cp vmlinuz /mnt/esp32boot/
sudo cp initramfs.img /mnt/esp32boot/

# Create grub.cfg or syslinux.cfg
# Example grub.cfg:
cat << 'EOF' | sudo tee /mnt/esp32boot/grub/grub.cfg
set timeout=5
set default=0
menuentry "Boot from ESP32 USB" {
    linux /vmlinuz root=/dev/sda1 rw
    initrd /initramfs.img
}
EOF

# 5. Unmount and test
sudo umount /mnt/esp32boot
```

### UEFI BIOS Settings (Bay Trail NUC)

- **Boot Mode**: UEFI only (disable CSM/Legacy)
- **Secure Boot**: Disabled (or enroll custom keys)
- **USB Legacy**: Disabled (or enabled for troubleshooting)
- Select the USB device in the boot device list

---

## 7. Testing

### Device-side Testing (`thumbdrive-test.sh`)

Run this script on the **host Linux machine** (your Chromebook, laptop, etc.)
when the ESP32-S3 is plugged in:

```bash
# Download the script
curl -sL -o thumbdrive-test.sh \
  https://raw.githubusercontent.com/rambalakrishnan/thumbdrive-esp-idf-v6.1/main/scripts/thumbdrive-test.sh
chmod +x thumbdrive-test.sh

# Run read-only tests
./thumbdrive-test.sh

# Run with verbose output and write verification
./thumbdrive-test.sh --verbose --write-test

# Specify device manually
./thumbdrive-test.sh --device /dev/sdb --verbose --write-test
```

**What it checks:**
1. Device auto-detection (size + sector size heuristic)
2. 512-byte logical sector size
3. Capacity (~15.75 MB)
4. MBR signature (0x55AA)
5. Partition table contents
6. Filesystem detection
7. Read integrity (10 sectors at various offsets + consistency check)
8. Write/read verification (optional — backs up and restores sector 100)
9. USB device info (VID/PID, Full-Speed 12 Mbps)

### Build Environment Testing (`validate.sh`)

Run this on the **devbox** to validate the build configuration:

```bash
cd ~/workspace/thumbdrive
source ~/workspace/esp/export.sh
bash scripts/validate.sh
```

**What it checks:**
1. Source file integrity (changelogs, no non-ASCII characters)
2. `sdkconfig.defaults` settings (16MB flash, 512-byte sectors, MSC enabled)
3. Partition table layout and alignment
4. Firmware source code (MOUNT_USB, v2.x TinyUSB API)
5. Component dependencies (esp_tinyusb v2.2.1)
6. Build outputs (binary sizes, flash config)
7. Flash command configuration
8. GitHub repository state (commits, release, tags)
9. Binary inspection (image headers, sizes)
10. `.gitignore` correctness

---

## 8. Partition Table

The project uses a **custom partition table** (`partitions.csv`) instead of
the default ESP-IDF single-app table. This is required because the default
table has no `storage` partition for the USB mass storage data.

| Partition | Type | Offset | Size | Description |
|---|---|---|---|---|
| `nvs` | data (nvs) | 0x09000 | 16 KB (0x4000) | NVS namespace storage |
| `phy_init` | data (phy) | 0x0D000 | 4 KB (0x1000) | WiFi PHY calibration |
| _(gap)_ | unused | 0x0E000 | 8 KB (0x2000) | Alignment padding |
| `factory` | app (factory) | 0x10000 | 192 KB (0x30000) | Application firmware |
| `storage` | data (fat) | 0x40000 | 15.75 MB (0xFC0000) | USB mass storage data |

**Total: 16 MB (0x1000000) — fills the entire flash.**

### Notes

- The 8 KB gap between `phy_init` and `factory` (0x0E000–0x10000) is
  required because ESP-IDF enforces **64 KB alignment** for APP-type
  partitions. The old layout used 0x0E000 (not aligned), which caused
  `gen_esp32part.py` to fail.
- The `factory` partition is 192 KB while the compiled firmware is ~195 KB.
  There is **1,008 bytes of free space** (0.5%). This is intentionally tight
  to maximise the storage partition. If you add features that increase code
  size, grow the factory partition:
  ```
  factory:    app,   factory,  0x10000,   0x40000,  # 256 KB
  storage:    data,  fat,      0x50000,   0xfb0000,  # ~15.67 MB
  ```
- NVS partition (16 KB) is retained. Removing it can cause ESP-IDF
  bootloader warnings. The user may experiment with removing it after
  the base configuration is known-good.

---

## 9. How It Works

### Firmware Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Host Linux Machine                    │
│                                                         │
│   fdisk ──► mkfs.fat ──► cp BOOTIA32.EFI ──► UEFI Boot   │
│        (512-byte sectors)        (FAT32 filesystem)      │
└──────────────────┬──────────────────────────────────────┘
                   │ USB Full-Speed (12 Mbps)
                   │ MSC BOT protocol
┌──────────────────▼──────────────────────────────────────┐
│  ESP32-S3 N16R8                                          │
│                                                          │
│  ┌─────────────┐    ┌──────────────┐    ┌────────────┐  │
│  │ Bootloader  │───▶│ Application  │───▶│ Wear       │  │
│  │ (14 KB)     │    │ (195 KB)     │    │ Levelling  │  │
│  │ @ 0x00000   │    │ @ 0x10000    │    │ Layer      │  │
│  └─────────────┘    │              │    │ (512-byte  │  │
│                     │ • TinyUSB    │    │ sectors)   │  │
│                     │   MSC driver │───▶│ @ 0x40000  │  │
│                     │ • wl_handle  │    │ (15.75 MB) │  │
│                     │   init       │    └────────────┘  │
│                     └──────────────┘                    │
└─────────────────────────────────────────────────────────┘
```

### Key Code Paths

The firmware's `main.c`:

1. **`nvs_flash_init()`** — Initialise NVS (required by ESP-IDF)
2. **`esp_partition_find_first(DATA, FAT, "storage")`** — Find the storage partition
3. **`wl_mount(storage_partition)`** — Mount wear-levelling driver on the storage partition
4. **`tinyusb_msc_new_storage_spiflash()`** — Configure MSC storage with:
   - `.medium.wl_handle = s_wl_handle` — Wear-levelling handle
   - `.mount_point = TINYUSB_MSC_STORAGE_MOUNT_USB` — **Raw sector mode (no FAT mount)**
   - `.fat_fs.do_not_format = false` — Irrelevant (FAT mount never runs)
5. **`tinyusb_driver_install(&config)`** — Start TinyUSB stack with `TINYUSB_DEFAULT_CONFIG()`

The `MOUNT_USB` setting means:
- `msc_storage_mount()` is **never called** (only called for `MOUNT_APP`)
- No FAT filesystem is mounted on the firmware side
- No auto-format (`f_mkfs`) is triggered
- The MSC callbacks (`tud_msc_read10_cb`, `tud_msc_write10_cb`) route directly
  through `storage_spiflash_sector_read()` → `wl_read()` and
  `storage_spiflash_sector_write()` → `wl_erase_range()` + `wl_write()`

### Wear-Levelling Transparency

The wear-levelling layer is completely transparent to the USB host:
- Virtual address 0 maps to physical flash at the start of the `storage` partition
- WL metadata (position tables, config) is stored at the **END** of the partition
- On first mount (blank flash), WL only erases the END sectors — sector 0 (MBR) is preserved
- The host reads/writes through WL which handles erase-before-write transparently

---

## 10. Project Structure

```
thumbdrive-esp-idf-v6.1/
├── README.md                   ← This file
├── test-requirements.md        ← Device testing documentation
├── CMakeLists.txt              ← Root CMake project definition
├── sdkconfig.defaults          ← Default build configuration
├── partitions.csv              ← Custom partition table (16 MB flash)
├── dependencies.lock         ← esp_tinyusb v2.2.1 dependency lock
├── .gitignore                 ← Build artifacts, managed_components, sdkconfig
├── CHANGELOG.md               ← Project changelog (if present)
│
├── main/
│   ├── CMakeLists.txt         ← Component: main (SRCS main.c, REQUIRES esp_tinyusb)
│   ├── idf_component.yml      ← Dependencies: espressif/esp_tinyusb ^2.2.1
│   └── main.c                 ← Application firmware (raw MSC, no FAT mount)
│
├── scripts/
│   ├── validate.sh            ← 10-suite build env validation (devbox)
│   └── thumbdrive-test.sh     ← 9-suite device validation (host Linux)
│
└── build/                     ← (gitignored) Build artifacts
    ├── usb_thumbdrive.bin     ← Firmware binary (195 KB)
    ├── bootloader/bootloader.bin  ← Bootloader (14 KB)
    ├── partition_table/partition-table.bin  ← Generated partition table
    ├── combined.bin           ← All 3 merged for flashing (256 KB)
    └── flash_args             ← Flash offsets and arguments
```

---

## 11. Troubleshooting

### Device Not Detected

| Symptom | Check |
|---|---|
| No new `/dev/sdX` after plugging in | Use a **data cable** (not charge-only); try different USB port |
| Device shows in `dmesg` but not `lsblk` | Firmware may not have started — check serial output at 115200 baud |
| Device is `/dev/mmcblkX` instead of `/dev/sdX` | The script auto-detects both; use `--device` to specify |
| No USB enumeration at all | ESP32-S3 in download mode? Power cycle the device |
| ChromeOS doesn't share USB with Crostini | Accept the "Share with Linux" notification; enable in `chrome://settings` |

### Wrong Sector Size (4096)

If `thumbdrive-test.sh` reports logical sector size = 4096:

```bash
# The firmware was built with CONFIG_WL_SECTOR_SIZE=4096
# Fix: rebuild with sdkconfig.defaults that has CONFIG_WL_SECTOR_SIZE_512=y
idf.py reconfigure
idf.py build
idf.py flash
```

### Binary Too Large for Partition

```
usb_thumbdrive.bin binary size 0x31000 bytes. Smallest app partition is 0x30000 bytes.
Warning: The smallest app partition is nearly full (0% free space left)!
```

If the firmware exceeds 192 KB, increase the factory partition:

```csv
# In partitions.csv:
factory,    app,   factory,  0x10000,   0x40000,   # 256 KB (was 192 KB)
storage,    data,  fat,      0x50000,   0xfb0000,  # ~15.67 MB (was 15.75 MB)
```

### UEFI Won't Boot

- Ensure `BOOTIA32.EFI` is at `\EFI\BOOT\BOOTIA32.EFI` (case-insensitive)
- Bay Trail NUC needs **32-bit** UEFI — use `BOOTIA32.EFI`, not `BOOTX64.EFI`
- Verify MBR + FAT32 were created on the **device** (`/dev/sdX`), not the **partition** (`/dev/sdX1`)

### Git Push Fails

```bash
# If HTTPS auth fails (headless environment), switch to SSH:
git remote set-url origin git@github.com:rambalakrishnan/thumbdrive-esp-idf-v6.1.git
git push
```

Verify SSH key: `ssh -T git@github.com`

---

## 12. License

This project is released under the MIT License.

```
MIT License

Copyright (c) 2026 R. Balakrishnan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so.
```

---

## Commit History

| Hash | Message |
|---|---|
| `042f011` | `test: add thumbdrive-test.sh for device-side USB MSC validation` |
| `25fdc70` | `test: add comprehensive validation script (scripts/validate.sh)` |
| `79b1897` | `chore: add changelog to root CMakeLists.txt + validation script` |
| `9e14538` | `feat(firmware): switch MOUNT_APP to MOUNT_USB for raw-sector MSC mode` |
| `95a41a3` | `fix(partitions): 192KB factory at 64KB-aligned offset, 15.75MB storage` |
| `ccf1ffe` | `fix(config): 16MB flash, custom partition table, 512-byte WL sectors` |
| `3b0784b` | `fix(firmware): rewrite main.c for esp_tinyusb v2.x MSC storage API` |
| `c9ffe7a` | `fix(build): remove redundant PRIV_INCLUDE_DIRS from main/CMakeLists.txt` |
| `d5cf18f` | `fix(config): enable TinyUSB MSC feature and align buffer/sector sizes` |
| `c775e85` | `fix(deps): bump espressif/esp_tinyusb from v1.7.6 to v2.2.1` |
| `1a3119a` | `chore: initial project structure — ESP-IDF v6.1-beta1 USB MSC thumbdrive` |

Full release history: https://github.com/rambalakrishnan/thumbdrive-esp-idf-v6.1/releases
