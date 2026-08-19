# Test Requirements: ESP32-S3 USB MSC Thumbdrive Device Validation

## 0. Executive Summary

We have an ESP32-S3 N16R8 module flashed with custom firmware that presents
itself to a host Linux machine as a **USB Mass Storage Class (MSC) device**.
The firmware is designed to be a **bootable USB drive for a Bay Trail NUC
with 32-bit UEFI**. The firmware presents the raw flash storage through a
wear-levelling layer, with **512-byte logical sectors**.

The `scripts/thumbdrive-test.sh` script automates validation of the device
when plugged into any Linux machine. This document explains everything
needed to test, debug, and improve that script.

---

## 1. Project Context

### 1.1 Hardware

| Component | Specification |
|---|---|
| **Microcontroller** | ESP32-S3 N16R8 |
| **Flash** | 16 MB (0x1000000 bytes) |
| **PSRAM** | 8 MB |
| **USB** | Full-Speed (12 Mbps), internal PHY |
| **Target use** | USB boot device for Bay Trail NUC (32-bit UEFI) |

### 1.2 Firmware Architecture

When the ESP32-S3 is powered on and connected to a host PC:

1. **Bootloader** (14 KB at flash 0x0) initializes the chip
2. **Partition table** (3 KB at flash 0x8000) defines memory layout:
   - `nvs` — 16 KB at 0x9000 (NVS namespace storage)
   - `phy_init` — 4 KB at 0xd000 (WiFi PHY calibration data)
   - `factory` — 192 KB at 0x10000 (the application firmware, ~195 KB)
   - `storage` — ~15.75 MB at 0x40000 (FAT-formatted mass storage data)
3. **Application** (195 KB at flash 0x10000) runs, initialising:
   - Wear-levelling layer (`wl_handle`) over the `storage` partition
   - TinyUSB MSC (Mass Storage Class) with `MOUNT_USB` config
   - USB enumeration as a bulk-only transport (BOT) MSC device

### 1.3 Key Design Decisions

- **`MOUNT_USB` (not `MOUNT_APP`)**: The firmware does NOT mount the FAT
  filesystem internally. Instead, it exposes raw sectors through the
  wear-levelling layer directly to the USB host. This means:
  - No auto-formatting on first boot
  - The host sees a raw block device (no filesystem until the host creates one)
  - MBR + FAT32 must be created by the host (e.g., via `fdisk` + `mkfs.fat`)
  - The MBR at sector 0 is visible to the host and can be modified

- **512-byte sector size**: The wear-levelling layer uses
  `CONFIG_WL_SECTOR_SIZE=512`. This is exposed to the USB host as the
  MSC logical block size. **UEFI firmware requires 512-byte sectors** —
  4096-byte sectors are rejected by most BIOS/UEFI implementations.

- **Wear-levelling metadata at END of partition**: The wear-levelling
  layer stores its metadata (position tables, config) at the END of the
  `storage` partition (flash 0x1000000 - metadata_size). This means
  sector 0 (MBR area) is at physical flash address `storage_start + 0`
  and is NOT erased or modified by wear-levelling initialization. Data
  written at sector 0 by the host is safely preserved.

### 1.4 Expected Host-Side Behaviour

When the device is plugged into Linux:

- A new block device appears in `/dev/` (e.g., `/dev/sdb`, `/dev/sdc`,
  or `/dev/mmcblk1` — the letter/number is non-deterministic)
- The device reports **512-byte** logical and physical sectors
- Total capacity: **~15.75 MB** (0xfc0000 bytes = 16,515,072 bytes)
- Initially, the device has **no partition table** and **no filesystem**
  — it is raw flash
- The user must create an MBR partition table and FAT32 filesystem:
  ```bash
  sudo fdisk /dev/sdX    # Create MBR (o), new partition (n), type 0c (FAT32 LBA)
  sudo mkfs.fat -F32 -n BOOT /dev/sdX1
  ```
- After formatting, the device will have a ~15.7 MB FAT32 filesystem

---

## 2. The Test Script (`scripts/thumbdrive-test.sh`)

### 2.1 What It Does

The script validates the USB MSC device on the **host Linux side**. It does
NOT require the ESP-IDF toolchain, the devbox, or any project source files.
It only needs standard Linux utilities.

### 2.2 Usage

```bash
# Auto-detect the device and run read-only tests
./scripts/thumbdrive-test.sh

# Specify the device manually
./scripts/thumbdrive-test.sh --device /dev/sdb

# Include write verification (backs up sector 100, writes test pattern, restores)
./scripts/thumbdrive-test.sh --write-test

# Verbose output (hex dumps)
./scripts/thumbdrive-test.sh --verbose

# Help
./scripts/thumbdrive-test.sh --help
```

### 2.3 Exit Codes

| Code | Meaning |
|---|---|
| `0` | All tests passed |
| `1` | One or more tests failed |
| `2` | No suitable device found |

### 2.4 Arguments

| Flag | Description |
|---|---|
| `--device /dev/sdX` | Specify the device path manually (skip auto-detection) |
| `--write-test` | Enable write verification (modifies sector 100, then restores) |
| `--verbose` | Show hex dumps and detailed information |
| `--help` / `-h` | Show help message |

---

## 3. Test Scenarios

### 3.1 Scenario 1: Device Not Connected

**Preconditions**: ESP32-S3 is NOT plugged in.

**Expected behavior**:
- Script runs device discovery (3 fallback methods)
- Reports "No ESP32-S3 USB MSC device found"
- Prints troubleshooting tips
- Exits with code 2

**What to check**:
- The troubleshooting tips are correct and actionable
- No false positives (no other block device is misidentified)
- The script exits cleanly (no crashes)

### 3.2 Scenario 2: Device Connected, No Filesystem (factory state)

**Preconditions**: ESP32-S3 is plugged in, device is raw (no MBR, no FAT32).

This is the state right after flashing `combined.bin` and booting the device.

**Expected behavior**:
- Device is auto-detected
- **Sector Size**: LOG-SEC = 512 ✓ (PASS)
- **Capacity**: ~15.75 MB ✓ (PASS)
- **MBR Signature**: No 0x55AA signature found ✓ (INFO/WARN — expected)
- **Partition Table**: No partitions detected ✓ (INFO — expected)
- **Filesystem**: No filesystem present ✓ (WARN — expected, needs formatting)
- **Read Test**: All sectors readable ✓ (PASS)
- **USB Info**: VID/PID detected, 12 Mbps speed ✓ (PASS)
- **Write Test**: (if enabled) Pattern written and read back ✓ (PASS)

**What to check**:
- MBR signature check correctly reports "no MBR" without crashing
- The script doesn't error when `fdisk` finds no partition table
- The read test covers sectors across the entire device (0, 1, 100, 1000, 32000)
- The write test correctly restores the original sector data

### 3.3 Scenario 3: Device Connected, MBR + FAT32 Created

**Preconditions**: ESP32-S3 is plugged in, user has run:
```bash
sudo fdisk /dev/sdX    # Created MBR + single partition
sudo mkfs.fat -F32 -n BOOT /dev/sdX1
```

**Expected behavior**:
- All tests from Scenario 2 should PASS
- **MBR Signature**: 0x55AA found ✓ (PASS)
- **Partition Table**: fdisk shows 1 partition ✓ (PASS)
- **Filesystem**: blkid detects vfat ✓ (PASS), label "BOOT" ✓ (PASS)

### 3.4 Scenario 4: Device Connected, Read-Only Mode

**Preconditions**: Device is read-only (firmware bug or USB cable issue).

**Expected behavior**:
- Read tests PASS
- Write test FAILS with clear error message
- USB info still works

### 3.5 Scenario 5: Wrong Device Specified

**Preconditions**: User runs `--device /dev/sda` but `/dev/sda` is their
internal hard drive (not the ESP32-S3).

**Expected behavior**: Test should detect the mismatch:
- Sector size might be 512 (PASS) but capacity won't match
- The script should warn about unexpected size
- Or, the script should refuse to run if the device doesn't match expected criteria

**What to check**: The script should have some sanity check to prevent
destructive operations on the wrong device. The `--write-test` flag should
double-check before writing.

---

## 4. Tools and Dependencies

The script should work on a **minimal Linux installation** including
**ChromeOS Crostini** (which has a very stripped-down environment).

### 4.1 Required Tools (absolute minimum)

| Tool | Source package | Purpose |
|---|---|---|
| `bash` | base | Script interpreter |
| `dd` | coreutils | Reading/writing sectors |
| `stat` | coreutils | File size checks |
| `grep` | grep | Pattern matching |
| `awk` | gawk/mawk | Field parsing |
| `cat`, `ls`, `find` | coreutils | File operations |

### 4.2 Optional Tools (with graceful fallbacks)

| Tool | Package | Purpose | Fallback if missing |
|---|---|---|---|
| `lsblk` | util-linux | Device enumeration, sector size | `/proc/partitions` + `/sys/block` |
| `blockdev` | util-linux | Sector size, size in sectors | `lsblk` or `/sys/block/*/size` |
| `fdisk` | util-linux | Partition table inspection | `/dev/sdX*` node check |
| `blkid` | util-linux | Filesystem detection | `file -s` |
| `file` | file | Filesystem magic detection | (inferred from read data) |
| `xxd` | vim-common | Hex dump | `hexdump -C` or `od` |
| `hexdump` | util-linux | Hex dump | `od` or `xxd` |
| `dmesg` | util-linux | Kernel messages | (skip) |
| `md5sum` | coreutils | Data consistency check | `md5` |
| `wc` | coreutils | Counting | (builtin arithmetic) |

### 4.3 Crostini-Specific Considerations

ChromeOS Crostini (Debian-based container) may lack:
- `fdisk` — not installed by default in minimal Crostini
- `blkid` — not installed by default
- `xxd` — not installed by default (but `hexdump` is usually present)
- `blockdev` — present in util-linux (usually installed)

**Testing on Crostini**:
1. Enable the container: `Settings -> Developers -> Linux (Crostini)`
2. The ESP32-S3 should appear as `/dev/sd*` inside the container
3. If tools are missing: `sudo apt install util-linux fdisk`

---

## 5. Debugging Guide

### 5.1 Device Not Detected

If the script says "No ESP32-S3 USB MSC device found":

1. **Check `lsblk`**:
   ```bash
   lsblk -o NAME,RM,SIZE,TYPE,MOUNTPOINT
   ```
   Look for a removable disk with ~15.75 MB size.

2. **Check `dmesg`**:
   ```bash
   dmesg | tail -20
   ```
   Look for lines like:
   ```
   usb 1-1: new high-speed USB device number 3 using xhci_hcd
   usb 1-1: New USB device found, idVendor=303a, idProduct=4002
   scsi 0:0:0:0: Direct-Access     ESP32 Mass Storage    0001 PQ: 0 ANSI: 0
   sd 0:0:0:0: [sdb] 32256 512-byte logical blocks: (16.5 MB, 15.75 MiB)
   ```

3. **Common causes**:
   - Device not powered (check USB cable — use data cable, not charge-only)
   - On Chromebook: USB device might need explicit sharing from ChromeOS to
     the Linux container (notification should appear — click "Share with Linux")
   - Firmware not flashed correctly (verify with `esptool.py`)

### 5.2 Wrong Sector Size

If the script reports `log-sec != 512`:
- This means the firmware is using `CONFIG_WL_SECTOR_SIZE=4096` instead of 512
- Rebuild with `sdkconfig.defaults` containing `CONFIG_WL_SECTOR_SIZE_512=y`
- Re-flash `combined.bin`

### 5.3 Write Test Fails

The write test writes to **sector 100** (byte offset 51,200). If this sector
contains important data (e.g., MBR backup), the test will temporarily corrupt it
but should restore it. If the device is read-only:
- Check USB cable (try a different cable)
- The device might be in read-only mode due to a firmware issue

### 5.4 Verbose Mode

Use `--verbose` to see:
- Hex dump of sector 0 (MBR area)
- Expected vs actual sector counts
- All device details

---

## 6. Test Execution Checklist

### Before testing:

- [ ] ESP32-S3 N16R8 is flashed with `combined.bin` (from GitHub release v0.1.0)
- [ ] USB cable is a **data cable** (not charge-only)
- [ ] Host machine has at least: bash, dd, grep, awk, stat, cat, ls

### Test matrix:

| Scenario | Device state | Flags | Expected outcome |
|---|---|---|---|
| 1 | No device | none | Exit 2, troubleshooting tips |
| 2 | Raw device (no FS) | none | All tests PASS except MBR/FS (INFO/WARN) |
| 3 | Raw device | --write-test | Write test PASS, data restored |
| 4 | Raw device | --verbose | Hex dump of sector 0 shown |
| 5 | MBR + FAT32 | none | All tests PASS |
| 6 | MBR + FAT32 | --write-test | Write test PASS on sector 100 (non-critical) |
| 7 | Wrong device | --device /dev/sda | Size check FAIL (not ESP32-S3 size) |

### On Chromebook/Crostini:

- [ ] ESP32-S3 appears in `lsblk` inside the Linux container
- [ ] If tools missing: `sudo apt install util-linux fdisk`
- [ ] If device needs sharing: accept ChromeOS notification "Shared with Linux"

---

## 7. Iteration Guidelines

When modifying `thumbdrive-test.sh`:

1. **Always test with `bash -n`** first:
   ```bash
   bash -n scripts/thumbdrive-test.sh
   ```
   This catches syntax errors without executing.

2. **Test without a device first**:
   ```bash
   ./scripts/thumbdrive-test.sh
   ```
   Verify it exits with code 2 and shows helpful troubleshooting.

3. **Test with `--device` on a non-existent device**:
   ```bash
   ./scripts/thumbdrive-test.sh --device /dev/sdz
   ```
   Should fail gracefully.

4. **Test with `--help`**:
   ```bash
   ./scripts/thumbdrive-test.sh --help
   ```
   Should show usage without errors.

5. **Test on the real device** (if available):
   ```bash
   ./scripts/thumbdrive-test.sh --verbose --write-test --device /dev/sdX
   ```

### Common fixes when iterating:

- **`grep` returns non-zero**: Always use `|| true` or capture to a variable
  before checking `$?`. With `set -euo pipefail`, any non-zero exit from `grep`
  will crash the script.

- **`grep -c` returns "0\n0"**: When grep fails AND `|| echo 0` also runs, you
  get two values. Use `tr -cd '0-9'` to normalize.

- **`awk` field extraction has whitespace**: CSV fields in partitions.csv have
  alignment spaces. Use `tr -d ' '` on awk output.

- **`grep -q` in pipeline causes SIGPIPE**: `cmd | grep -q pattern` makes `cmd`
  receive SIGPIPE (exit 141) when grep exits early. With `pipefail`, the
  pipeline returns 141. Fix: capture output first (`output=$(cmd)`), then
  `echo "$output" | grep -q pattern`.

- **`/dev/sdX` naming is non-deterministic**: Linux assigns letters
  alphabetically. The same device might be `/dev/sdb` on one boot and
  `/dev/sdc` on another. Auto-detection by size + sector size is more
  reliable. Also check `/dev/mmcblk*` for SD-card-style adapters.

- **`lsblk` may not show `LOG-SEC`**: Older versions of `lsblk` don't have
  `LOG-SEC` column. Use `blockdev --getss` as primary, `lsblk` as fallback.

- **Non-ASCII in heredocs**: The script uses Unicode box-drawing characters
  for visual output. These are fine for terminal display but ensure the
  script file itself is UTF-8 encoded.

---

## 8. What "Passing" Means

### Read-only mode (no `--write-test`):

- **Device Discovery**: 1 device found ✓
- **Sector Size**: 512 bytes ✓ (FAIL if 4096)
- **Capacity**: 14–16.5 MB ✓ (this is a device with ~15.75 MB of flash, but
  the wear-levelling layer may report slightly different capacity)
- **MBR Signature**: 0x55AA present IF the user has already partitioned the
  device; absent is INFO (not a failure) for a fresh device
- **Read Integrity**: All tested sectors return 512 bytes; sector 0 is
  consistent across two reads

### Write test mode (`--write-test`):

- All read-only tests must pass
- **Write/Read**: Test pattern written to sector 100, read back, matches ✓
- **Overwrite**: Second pattern written, read back, matches ✓
- **Restore**: Original sector 100 data written back successfully ✓

### Failure = the device is unusable as a boot medium:

- Sector size ≠ 512 → UEFI won't boot
- Capacity too small → can't hold UEFI bootloader + OS
- Read failures → bad flash or firmware bug
- Write failures → firmware MSC implementation broken
- Inconsistent reads → firmware data corruption bug

---

## 9. File Layout Reference

```
/home/whipsthellamasass/workspace/thumbdrive/
├── CMakeLists.txt              ← Root project file (changelog prepended)
├── sdkconfig.defaults         ← Build configuration (16MB flash, 512-byte sectors)
├── partitions.csv             ← Partition table (nvs/phy/factory/storage)
├── .gitignore                 ← Excludes build/, managed_components/, sdkconfig
├── dependencies.lock          ← esp_tinyusb v2.2.1 lock
├── scripts/
│   ├── validate.sh            ← Build-environment validation (runs on devbox)
│   └── thumbdrive-test.sh     ← Device-side validation (runs on any Linux host)
├── main/
│   ├── CMakeLists.txt         ← Component registration
│   ├── idf_component.yml      ← Dependencies (esp_tinyusb ^2.2.1)
│   └── main.c                 ← Application firmware (MOUNT_USB, raw MSC)
└── build/                     ← (gitignored) Build artifacts
    ├── usb_thumbdrive.bin     ← Firmware binary (195 KB)
    ├── bootloader/bootloader.bin  ← Bootloader (14 KB)
    ├── partition_table/partition-table.bin  ← Generated partition table
    └── combined.bin           ← All three merged for flashing (256 KB)
```

---

## 10. Quick Reference: Flashing the Device

```bash
# 1. Download firmware
curl -L -o combined.bin \
  https://github.com/rambalakrishnan/thumbdrive-esp-idf-v6.1/releases/download/v0.1.0/combined.bin

# 2. Verify integrity
md5sum combined.bin
# Expected: 95b89cc83c96cd65c63626a12bc9fcd3

# 3. Flash via web.esphome.io (Chrome/Edge):
#    - Go to https://web.esphome.io
#    - Click "Connect", select USB-to-UART adapter
#    - Put ESP32-S3 in download mode (hold BOOT, press RST, release BOOT)
#    - Upload mode: "Flash at 0x0"
#    - Select combined.bin → Install

# 4. After flashing, test:
./scripts/thumbdrive-test.sh --verbose

# 5. Partition + format (on host):
sudo fdisk /dev/sdX      # o (MBR), n (partition), t (0c = FAT32 LBA), w
sudo mkfs.fat -F32 -n BOOT /dev/sdX1
```
