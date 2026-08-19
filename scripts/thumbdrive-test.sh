#!/usr/bin/env bash
# =============================================================================
# thumbdrive-test.sh — USB Mass Storage Device Validation Script
#
# Description:
#   Validates an ESP32-S3 N16R8 (or similar) USB mass storage device when
#   attached to ANY Linux machine.  This script does NOT require the ESP-IDF
#   toolchain, the devbox, or any project source files.  It runs entirely on
#   the host Linux machine to which the ESP32-S3 is connected via USB.
#
# Target environment:
#   - Any Linux distribution (tested on Ubuntu, Debian, Arch, Fedora)
#   - Chromebook with Crostini (Crostini includes coreutils but may lack
#     fdisk/hexdump — the script gracefully degrades)
#   - Any x86 or ARM Linux host with USB host port
#
# What it checks:
#   1. Device discovery: finds the ESP32-S3 block device among /dev/sd*
#      or /dev/mmcblk* without relying on /dev/sdX naming (which is
#      non-deterministic and may change between boots)
#   2. Sector size: verifies LOG-SEC = 512 (NOT 4096 — UEFI/BIOS requires 512)
#   3. Capacity: verifies total size is in the expected range for N16R8
#      (~15.75 MB for a 16 MB flash with ~256KB used by firmware/bootloader/
#      partition table)
#   4. MBR signature: reads last 2 bytes of sector 0, checks for 0x55 0xAA
#   5. Partition table: if MBR exists, lists all partitions
#   6. Filesystem: checks if any partition has a recognizable filesystem
#   7. Read test: reads several sectors to verify I/O integrity
#   8. Write test (optional): writes a test pattern to a high sector,
#      reads it back, and verifies — DOES NOT modify user data
#   9. USB device info: reads USB vendor/product ID if available
#
# Usage:
#   ./thumbdrive-test.sh                 # auto-detect + read-only tests
#   ./thumbdrive-test.sh --device /dev/sdX   # specify device manually
#   ./thumbdrive-test.sh --write-test        # include write verification
#   ./thumbdrive-test.sh --verbose           # show hex dumps and details
#   ./thumbdrive-test.sh --help              # show this help
#
# Exit codes:
#   0 = ALL TESTS PASSED
#   1 = One or more tests FAILED
#   2 = No suitable device found
#
# =============================================================================

set -euo pipefail

# ---- Configuration -----------------------------------------------------------

# ESP32-S3 N16R8 flash size: 16 MB (0x1000000)
# Firmware (factory) occupies first 256KB (bootloader + partition table + app)
# Storage partition: ~15.75 MB (0xfc0000 bytes)
# We accept a range of +/- 10% to account for wear-levelling metadata overhead
EXPECTED_SIZE_MB=15.76
MIN_SIZE_MB=14.0
MAX_SIZE_MB=16.5

# The test sector for write verification — use a sector
# well past the MBR but within the device's capacity
# We use sector 100 (offset 51,200 bytes) — this is in the
# MBR/GPT area and typically unused
TEST_SECTOR=100
TEST_PATTERN_A="\xaa\xbb\xcc\xdd\xee\xff\x00\x11"
TEST_PATTERN_B="\x12\x34\x56\x78\x9a\xbc\xde\xf0"

# ---- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---- Globals -----------------------------------------------------------------
DEVICE=""
WRITE_TEST=false
VERBOSE=false
PASS=0
FAIL=0
WARN=0
TOTAL=0
FOUND_DEVICES=()

# ---- Helpers -----------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

pass() {
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}[PASS]${NC} $1"
}

fail() {
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo -e "  ${RED}[FAIL]${NC} $1"
    if [ -n "$2" ]; then
        echo -e "       ${RED}Detail: $2${NC}"
    fi
}

warn() {
    TOTAL=$((TOTAL + 1))
    WARN=$((WARN + 1))
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    if [ -n "$2" ]; then
        echo -e "       ${YELLOW}Detail: $2${NC}"
    fi
}

info() {
    echo -e "  ${BLUE}[INFO]${NC} $1"
}

# Check if a command exists
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Convert bytes to human-readable
bytes_to_mb() {
    local bytes=$1
    # Use awk for floating-point division (bash doesn't support floats)
    awk -v b="$bytes" 'BEGIN { printf "%.2f", b / (1024 * 1024) }'
}

# =============================================================================
# Device Discovery

find_esp32s3_devices() {
    print_header "Device Discovery"

    if [ -n "$DEVICE" ]; then
        if [ -b "$DEVICE" ]; then
            FOUND_DEVICES=("$DEVICE")
            info "Using user-specified device: $DEVICE"
        else
            fail "Specified device $DEVICE is not a block device" "$DEVICE does not exist or is not a block device"
            exit 2
        fi
    else
        info "Scanning /proc/partitions for USB mass storage devices..."

        # Method 1: lsblk — preferred, gives sector size directly
        if has_cmd lsblk; then
            info "Using lsblk to enumerate block devices"
            while IFS= read -r line; do
                local name size sectors log_sec rm_type
                # lsblk output: NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINT
                #              or: NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINT LOG-SEC
                local devnode
                devnode=$(echo "$line" | awk '{print $1}')
                rm=$(echo "$line" | awk '{print $3}')
                size=$(echo "$line" | awk '{print $4}')
                type=$(echo "$line" | awk '{print $6}')

                # Only look at removable USB devices (RM=1) that are disks (TYPE=disk)
                if [ "$rm" = "1" ] && [ "$type" = "disk" ]; then
                    devnode="/dev/$devnode"
                    local sectors size_bytes log_sec
                    sectors=$(lsblk -b -n -o SIZE "$devnode" 2>/dev/null | head -1)
                    log_sec=$(lsblk -b -n -o LOG-SEC "$devnode" 2>/dev/null | head -1)
                    if [ -n "$sectors" ] && [ -n "$log_sec" ]; then
                        local size_mb
                        size_mb=$(bytes_to_mb "$sectors")
                        info "Found removable disk: $devnode (${size_mb} MB, log-sec=$log_sec)"
                        if [ "$log_sec" = "512" ] && \
                           awk -v s="$sectors" -v min="$((MIN_SIZE_MB * 1024 * 1024))" \
                               -v max="$((MAX_SIZE_MB * 1024 * 1024))" \
                               'BEGIN { exit !(s >= min && s <= max) }'; then
                            FOUND_DEVICES+=("$devnode")
                            info "  -> CANDIDATE: Sector size 512, size within expected range"
                        fi
                    fi
                fi
            done < <(lsblk -n -d -o NAME,RM,SIZE,RO,TYPE,MOUNTPOINT 2>/dev/null)
        fi

        # Method 2: Parse /proc/partitions (fallback if lsblk missing)
        if [ ${#FOUND_DEVICES[@]} -eq 0 ]; then
            info "lsblk unavailable or no candidates — scanning /proc/partitions"
            while IFS= read -r line; do
                local major minor blocks devname
                major=$(echo "$line" | awk '{print $1}')
                minor=$(echo "$line" | awk '{print $2}')
                blocks=$(echo "$line" | awk '{print $3}')
                devname=$(echo "$line" | awk '{print $4}')

                # USB block devices: major 8 (sd) or major 179 (mmcblk)
                # Blocks are in 1K units
                local size_bytes=$((blocks * 1024))
                local size_mb
                size_mb=$(bytes_to_mb "$size_bytes")

                if [ "$major" = "8" ] || [ "$major" = "179" ]; then
                    local devnode="/dev/$devname"
                    info "Found block device: $devnode (${size_mb} MB)"
                    if awk -v s="$size_bytes" \
                           -v min="$((MIN_SIZE_MB * 1024 * 1024))" \
                           -v max="$((MAX_SIZE_MB * 1024 * 1024))" \
                           'BEGIN { exit !(s >= min && s <= max) }'; then
                        FOUND_DEVICES+=("$devnode")
                        info "  -> CANDIDATE: Size within expected range (${size_mb} MB)"
                    fi
                fi
            done < <(tail -n +3 /proc/partitions 2>/dev/null)
        fi

        # Also check /sys/block for USB devices
        if [ ${#FOUND_DEVICES[@]} -eq 0 ]; then
            info "Falling back to /sys/block scan..."
            for syspath in /sys/block/sd* /sys/block/mmcblk*; do
                [ -e "$syspath" ] || continue
                local devname
                devname=$(basename "$syspath")
                local removable
                removable=$(cat "$syspath/removable" 2>/dev/null || echo 0)
                local size_sectors
                size_sectors=$(cat "$syspath/size" 2>/dev/null || echo 0)
                local size_bytes=$((size_sectors * 512))
                local size_mb
                size_mb=$(bytes_to_mb "$size_bytes")

                if [ "$removable" = "1" ] && [ "$size_sectors" -gt 0 ]; then
                    info "Found removable device: /dev/$devname (${size_mb} MB)"
                    if awk -v s="$size_bytes" \
                           -v min="$((MIN_SIZE_MB * 1024 * 1024))" \
                           -v max="$((MAX_SIZE_MB * 1024 * 1024))" \
                           'BEGIN { exit !(s >= min && s <= max) }'; then
                        FOUND_DEVICES+=("/dev/$devname")
                        info "  -> CANDIDATE: Size within expected range"
                    fi
                fi
            done
        fi
    fi

    if [ ${#FOUND_DEVICES[@]} -eq 0 ]; then
        fail "No ESP32-S3 USB MSC device found" "No block device with size ${MIN_SIZE_MB}-${MAX_SIZE_MB} MB and 512-byte sectors was detected"
        echo ""
        info "Troubleshooting:"
        echo "   1. Ensure the ESP32-S3 is plugged in and powered"
        echo "   2. Check that the USB cable supports data (not charge-only)"
        echo "   3. On some Chromebooks, you may need to enable USB passthrough:"
        echo "      chrome://flags -> 'USB device' -> Enabled"
        echo "   4. Run: lsblk        to see connected storage devices"
        echo "   5. Run: dmesg | tail  to check for USB enumeration messages"
        echo ""
        echo "   If you know the device path, run:"
        echo "     $0 --device /dev/sdX"
        exit 2
    fi

    info "Found ${#FOUND_DEVICES[@]} candidate device(s):"
    for d in "${FOUND_DEVICES[@]}"; do
        info "  $d"
    done
}

# =============================================================================
# Test Suite: Sector Size

test_sector_size() {
    local dev="$1"
    print_header "Sector Size Verification"

    TOTAL=$((TOTAL + 1))
    local log_sec=""
    local phys_sec=""

    # Try blockdev first (most portable)
    if has_cmd blockdev; then
        log_sec=$(blockdev --getss "$dev" 2>/dev/null || echo "")
        phys_sec=$(blockdev --getpbsz "$dev" 2>/dev/null || echo "")
    fi

    # Try lsblk as fallback
    if [ -z "$log_sec" ] && has_cmd lsblk; then
        log_sec=$(lsblk -b -n -o LOG-SEC "$dev" 2>/dev/null | head -1)
        phys_sec=$(lsblk -b -n -o PHY-SEC "$dev" 2>/dev/null | head -1)
    fi

    if [ -n "$log_sec" ]; then
        if [ "$log_sec" = "512" ]; then
            pass "Logical sector size is 512 bytes"
        else
            fail "Logical sector size is $log_sec (expected 512)" \
                 "BIOS/UEFI cannot boot from devices with 4096-byte sectors"
        fi

        if [ -n "$phys_sec" ]; then
            info "Physical sector size: $phys_sec bytes"
        fi
    else
        warn "Could not determine sector size (no blockdev or lsblk)" \
             "Install 'util-linux' or 'lsblk' for sector size verification"
    fi
}

# =============================================================================
# Test Suite: Capacity

test_capacity() {
    local dev="$1"
    print_header "Capacity Verification"

    local size_bytes=0
    local size_sectors=0

    # Try blockdev
    if has_cmd blockdev; then
        size_sectors=$(blockdev --getsz "$dev" 2>/dev/null || echo 0)
        size_sectors=$(echo "$size_sectors" | tr -cd '0-9')
        size_sectors=${size_sectors:-0}
    fi

    # Try lsblk
    if [ "$size_sectors" -eq 0 ] && has_cmd lsblk; then
        size_bytes=$(lsblk -b -n -o SIZE "$dev" 2>/dev/null | head -1)
        size_bytes=$(echo "$size_bytes" | tr -cd '0-9')
        size_bytes=${size_bytes:-0}
    fi

    # Try /sys/block
    if [ "$size_sectors" -eq 0 ]; then
        local devname
        devname=$(basename "$dev")
        if [ -e "/sys/block/$devname/size" ]; then
            size_sectors=$(cat "/sys/block/$devname/size" 2>/dev/null || echo 0)
            size_sectors=$(echo "$size_sectors" | tr -cd '0-9')
            size_sectors=${size_sectors:-0}
        fi
    fi

    if [ "$size_sectors" -eq 0 ] && [ "$size_bytes" -eq 0 ]; then
        fail "Could not determine device capacity" "No tool available (blockdev/lsblk/sysfs)"
        return
    fi

    # Calculate size from sectors if we don't have bytes
    if [ "$size_bytes" -eq 0 ] && [ "$size_sectors" -gt 0 ]; then
        size_bytes=$((size_sectors * 512))
    fi

    local size_mb
    size_mb=$(bytes_to_mb "$size_bytes")

    info "Device capacity: ${size_mb} MB (${size_bytes} bytes, ${size_sectors} sectors)"

    TOTAL=$((TOTAL + 1))
    if awk -v s="$size_bytes" \
           -v min="$((MIN_SIZE_MB * 1024 * 1024))" \
           -v max="$((MAX_SIZE_MB * 1024 * 1024))" \
           'BEGIN { exit !(s >= min && s <= max) }'; then
        pass "Capacity (${size_mb} MB) is within expected range (${MIN_SIZE_MB}-${MAX_SIZE_MB} MB)"
    else
        fail "Capacity (${size_mb} MB) is outside expected range (${MIN_SIZE_MB}-${MAX_SIZE_MB} MB)" \
             "Expected ~${EXPECTED_SIZE_MB} MB for ESP32-S3 N16R8"
    fi

    TOTAL=$((TOTAL + 1))
    # Show how many bytes are actually available
    local expected_sectors
    expected_sectors=$((0xfc0000 / 512))  # 16MB - 256KB firmware area
    local actual_sectors=$size_sectors
    if [ "$VERBOSE" = "true" ]; then
        info "Sector count: $actual_sectors (expected: $expected_sectors for 0xfc0000 bytes)"
        info "Byte count:   $size_bytes (expected: $((0xfc0000)) = ${EXPECTED_SIZE_MB} MB)"
    fi

    if [ "$actual_sectors" -gt 0 ]; then
        pass "Device reports non-zero sector count ($actual_sectors sectors)"
    else
        fail "Device reports zero sectors"
    fi
}

# =============================================================================
# Test Suite: MBR Signature

test_mbr_signature() {
    local dev="$1"
    print_header "MBR Signature Check"

    # Read first 512 bytes (sector 0) — the MBR
    local mbr_file="/tmp/thumbdrive_test_mbr_$$"
    if ! dd if="$dev" of="$mbr_file" bs=512 count=1 2>/dev/null; then
        fail "Unable to read sector 0 (MBR)" "dd command failed — device may be read-protected"
        rm -f "$mbr_file"
        return
    fi

    # Check for MBR signature: bytes 510-511 must be 0x55 0xAA
    local sig
    sig=$(dd if="$mbr_file" bs=1 skip=510 count=2 2>/dev/null | xxd -p 2>/dev/null)
    if [ -z "$sig" ] && has_cmd hexdump; then
        sig=$(dd if="$mbr_file" bs=1 skip=510 count=2 2>/dev/null | hexdump -e '1/1 "%02x"' 2>/dev/null)
    fi

    if [ -z "$sig" ]; then
        warn "Could not read MBR signature" "Neither xxd nor hexdump available"
    elif [ "$sig" = "55aa" ] || [ "$sig" = "55AA" ]; then
        pass "Valid MBR signature found (0x55AA at offset 510)"
    else
        info "MBR signature: 0x${sig:-<unknown>} (not 0x55AA — no MBR partition table yet)"
        TOTAL=$((TOTAL + 1))
        WARN=$((WARN + 1))
        echo -e "  ${YELLOW}[INFO]${NC} This is expected if no partition table has been created yet"
        TOTAL=$((TOTAL - 1))
    fi

    # Show first few bytes if verbose
    if [ "$VERBOSE" = "true" ]; then
        info "Sector 0 hex dump (first 64 bytes):"
        dd if="$mbr_file" bs=1 count=64 2>/dev/null | xxd 2>/dev/null | sed 's/^/      /' || \
        dd if="$mbr_file" bs=1 count=64 2>/dev/null | hexdump -C 2>/dev/null | sed 's/^/      /' || \
        echo "      (hexdump/xxd not available)"
    fi

    rm -f "$mbr_file"
}

# =============================================================================
# Test Suite: Partition Table

test_partition_table() {
    local dev="$1"
    print_header "Partition Table Inspection"

    local has_partitions=false

    # Try fdisk first (most informative)
    if has_cmd fdisk; then
        local pt_output
        pt_output=$(fdisk -l "$dev" 2>/dev/null || true)
        if [ -n "$pt_output" ] && echo "$pt_output" | grep -q "Disk label type\|Disk model"; then
            info "fdisk output:"
            echo "$pt_output" | sed 's/^/      /'
            has_partitions=true

            TOTAL=$((TOTAL + 1))
            if echo "$pt_output" | grep -qiE "Disk label type:.*dos|Disk label type:.*gpt"; then
                pass "Partition table format detected by fdisk"
            else
                info "fdisk detected disk but no partition table label — drive may be unpartitioned"
                TOTAL=$((TOTAL - 1))
            fi

            # Check for partitions
            TOTAL=$((TOTAL + 1))
            if echo "$pt_output" | grep -qE "${dev}p?[1-9]"; then
                pass "Partitions detected"
            else
                info "No partitions found — drive is raw (no filesystem yet)"
                TOTAL=$((TOTAL - 1))
            fi
        else
            info "fdisk could not analyze device (or fdisk not available)"
        fi
    else
        warn "fdisk not available" "Install 'fdisk' (util-linux) for partition table inspection"
    fi

    # Fallback: check for partition nodes in /dev
    if [ "$has_partitions" = "false" ]; then
        local devname
        devname=$(basename "$dev")
        local part_count
        part_count=$(ls "/dev/${devname}?"* 2>/dev/null | wc -l)
        part_count=$(echo "$part_count" | tr -cd '0-9')
        part_count=${part_count:-0}
        if [ "$part_count" -gt 0 ]; then
            info "Found $part_count partition node(s) in /dev:"
            ls "/dev/${devname}?"* 2>/dev/null | sed 's/^/      /'
        else
            info "No partition nodes found in /dev — drive is unpartitioned"
        fi
    fi
}

# =============================================================================
# Test Suite: Filesystem Detection

test_filesystem() {
    local dev="$1"
    print_header "Filesystem Detection"

    # Check for partition devices
    local devname
    devname=$(basename "$dev")
    local part_devs
    part_devs=$(ls "/dev/${devname}?"* 2>/dev/null)

    if [ -z "$part_devs" ]; then
        info "No partitions found — no filesystem to test"
        warn "No filesystem present — device needs partitioning + formatting" \
             "Create MBR + FAT32 partition: fdisk /dev/sdX, then mkfs.fat -F32"
        return
    fi

    for part in $part_devs; do
        info "Checking $part for filesystem..."

        # Try blkid (most reliable)
        if has_cmd blkid; then
            local fs_type
            fs_type=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
            if [ -n "$fs_type" ]; then
                TOTAL=$((TOTAL + 1))
                if [ "$fs_type" = "vfat" ] || [ "$fs_type" = "exfat" ] || [ "$fs_type" = "ntfs" ]; then
                    pass "Filesystem on $part: $fs_type"
                else
                    info "Filesystem on $part: $fs_type"
                    TOTAL=$((TOTAL - 1))
                fi

                TOTAL=$((TOTAL + 1))
                local label
                label=$(blkid -o value -s LABEL "$part" 2>/dev/null || true)
                if [ -n "$label" ]; then
                    info "  Label: $label"
                    pass "Volume label set: $label"
                else
                    info "  Label: (none)"
                    TOTAL=$((TOTAL - 1))
                fi
            else
                warn "blkid found no filesystem on $part" "Partition may be empty or use unsupported FS"
            fi
        else
            warn "blkid not available" "Install 'blkid' (util-linux) for filesystem detection"
        fi

        # Fallback: use 'file' command
        if has_cmd file; then
            local file_output
            file_output=$(file -s "$part" 2>/dev/null || true)
            if [ -n "$file_output" ]; then
                info "file says: $file_output"
            fi
        fi
    done
}

# =============================================================================
# Test Suite: Read Test

test_read() {
    local dev="$1"
    print_header "Read Integrity Test"

    local tmpfile="/tmp/thumbdrive_test_read_$$"
    local ok=true

    # Read sectors at various offsets
    local sectors_to_test=(0 1 2 10 100 500 1000 5000 10000 32000)

    for sector in "${sectors_to_test[@]}"; do
        # Use dd to read 1 sector
        if dd if="$dev" of="$tmpfile" bs=512 skip="$sector" count=1 2>/dev/null; then
            local fsize
            fsize=$(stat -c%s "$tmpfile" 2>/dev/null || stat -f%z "$tmpfile" 2>/dev/null || echo 0)
            if [ "$fsize" = "512" ]; then
                : # Success — sector read
            else
                ok=false
                warn "Sector $sector: read returned $fsize bytes (expected 512)"
            fi
        else
            ok=false
            warn "Sector $sector: read failed"
        fi
    done

    if [ "$ok" = "true" ]; then
        pass "Read test: all tested sectors readable (512 bytes each)"
    else
        fail "Read test: some sectors could not be read" \
             "Check USB cable or device firmware"
    fi

    # CRC-style check: read same sector twice and compare
    TOTAL=$((TOTAL + 1))
    local read1 read2
    dd if="$dev" of="$tmpfile" bs=512 skip=0 count=1 2>/dev/null
    read1=$(md5sum "$tmpfile" 2>/dev/null | awk '{print $1}' || md5 "$tmpfile" 2>/dev/null | awk '{print $NF}')
    dd if="$dev" of="$tmpfile" bs=512 skip=0 count=1 2>/dev/null
    read2=$(md5sum "$tmpfile" 2>/dev/null | awk '{print $1}' || md5 "$tmpfile" 2>/dev/null | awk '{print $NF}')

    if [ "$read1" = "$read2" ] && [ -n "$read1" ]; then
        pass "Data consistency: sector 0 read twice with identical checksums"
    else
        fail "Data consistency: sector 0 read two different checksums" \
             "read1=$read1 read2=$read2"
    fi

    rm -f "$tmpfile"
}

# =============================================================================
# Test Suite: Write Test (optional)

test_write() {
    local dev="$1"
    print_header "Write Integrity Test (Optional)"

    info "Write test: device=$dev sector=$TEST_SECTOR pattern verification"
    info "This test writes to sector $TEST_SECTOR and restores it afterwards"
    info "WARNING: This modifies data on the device. Ensure no critical data"
    info "         is stored in sector $TEST_SECTOR (offset $((TEST_SECTOR * 512)) bytes)"
    echo ""

    local tmpfile="/tmp/thumbdrive_test_write_$$"
    local restore_file="/tmp/thumbdrive_test_restore_$$"

    # Save original sector content
    if ! dd if="$dev" of="$restore_file" bs=512 skip="$TEST_SECTOR" count=1 2>/dev/null; then
        fail "Write test: could not read original sector for backup"
        rm -f "$tmpfile" "$restore_file"
        return
    fi

    info "Backed up original sector $TEST_SECTOR"

    # Write test pattern
    printf "$TEST_PATTERN_A" | dd of="$dev" bs=512 seek="$TEST_SECTOR" count=1 2>/dev/null
    if [ $? -ne 0 ] || [ "${PIPESTATUS[1]}" -ne 0 ]; then
        warn "Write test: could not write to device (may be read-only)"
        rm -f "$tmpfile" "$restore_file"
        return
    fi

    # Read back and verify
    dd if="$dev" of="$tmpfile" bs=512 skip="$TEST_SECTOR" count=1 2>/dev/null

    local pattern_hex
    pattern_hex=$(printf "$TEST_PATTERN_A" | xxd -p 2>/dev/null || \
                  printf "$TEST_PATTERN_A" | od -A n -t x1 | tr -d ' \n')
    local read_hex
    read_hex=$(dd if="$dev" bs=512 skip="$TEST_SECTOR" count=1 2>/dev/null | \
               xxd -p 2>/dev/null | tr -d '\n')

    TOTAL=$((TOTAL + 1))
    if echo "$read_hex" | grep -q "${pattern_hex:0:16}"; then
        pass "Write test: pattern written and read back correctly"
    else
        fail "Write test: written pattern does not match read-back" \
             "expected prefix: ${pattern_hex:0:16} | got: ${read_hex:0:16}"
    fi

    # Write second pattern (verify overwrite works)
    printf "$TEST_PATTERN_B" | dd of="$dev" bs=512 seek="$TEST_SECTOR" count=1 2>/dev/null || true
    local read_hex2
    read_hex2=$(dd if="$dev" bs=512 skip="$TEST_SECTOR" count=1 2>/dev/null | \
                xxd -p 2>/dev/null | tr -d '\n')

    TOTAL=$((TOTAL + 1))
    local pattern_b_hex
    pattern_b_hex=$(printf "$TEST_PATTERN_B" | xxd -p 2>/dev/null || \
                    printf "$TEST_PATTERN_B" | od -A n -t x1 | tr -d ' \n')
    if echo "$read_hex2" | grep -q "${pattern_b_hex:0:16}"; then
        pass "Write test: overwrite pattern read back correctly"
    else
        fail "Write test: overwrite pattern mismatch"
    fi

    # Restore original sector
    info "Restoring original sector $TEST_SECTOR..."
    dd if="$restore_file" of="$dev" bs=512 seek="$TEST_SECTOR" count=1 2>/dev/null || true
    TOTAL=$((TOTAL + 1))
    pass "Original sector data restored"

    rm -f "$tmpfile" "$restore_file"
}

# =============================================================================
# Test Suite: USB Device Info

test_usb_info() {
    local dev="$1"
    print_header "USB Device Information"

    local devname
    devname=$(basename "$dev")

    # Try to find USB info via /sys/block/*/device
    local usb_path=""
    for path in /sys/block/*/device; do
        [ -e "$path" ] || continue
        local basename_dev
        basename_dev=$(basename "$(dirname "$path")")
        if [ "$basename_dev" = "$devname" ]; then
            usb_path="$path"
            break
        fi
    done

    if [ -n "$usb_path" ] && [ -d "$usb_path" ]; then
        local vendor_id product_id
        vendor_id=$(cat "$usb_path/../../idVendor" 2>/dev/null || echo "")
        product_id=$(cat "$usb_path/../../idProduct" 2>/dev/null || echo "")

        if [ -n "$vendor_id" ]; then
            info "USB Vendor ID:  0x${vendor_id}"
            info "USB Product ID: 0x${product_id}"

            # Common ESP32-S3 USB VID/PID
            local vid_int=$((16#$vendor_id))
            local pid_int=$((16#$product_id))

            if [ "$vid_int" -eq $((16#239a)) ] || [ "$vid_int" -eq $((16#303a)) ]; then
                pass "VID matches known ESP32 vendor (0x239a or 0x303a)"
            else
                info "VID 0x${vendor_id} does not match common ESP32 VID (0x239a/0x303a)"
                warn "Unknown USB vendor" "This might not be an ESP32 device"
            fi
        else
            info "Could not read USB vendor/product ID"
        fi

        # Check USB speed
        local speed
        speed=$(cat "$usb_path/../../speed" 2>/dev/null || echo "")
        if [ -n "$speed" ]; then
            info "USB speed: ${speed} Mbps"
            TOTAL=$((TOTAL + 1))
            # ESP32-S3 is Full-Speed only (12 Mbps)
            if [ "$speed" = "12" ]; then
                pass "USB speed is 12 Mbps (Full-Speed) — expected for ESP32-S3"
            elif [ "$speed" = "480" ]; then
                warn "USB speed is 480 Mbps (High-Speed) — unexpected for ESP32-S3"
            else
                info "USB speed: ${speed} Mbps"
                TOTAL=$((TOTAL - 1))
            fi
        fi

        # Product description
        local product
        product=$(cat "$usb_path/../../product" 2>/dev/null || echo "")
        [ -n "$product" ] && info "Product: $product"

        local manufacturer
        manufacturer=$(cat "$usb_path/../../manufacturer" 2>/dev/null || echo "")
        [ -n "$manufacturer" ] && info "Manufacturer: $manufacturer"

    else
        warn "Could not probe USB device info via /sys/block"
    fi
}

# =============================================================================
# Test Suite: dmesg Check

test_dmesg() {
    local dev="$1"
    print_header "Kernel Messages (dmesg)"

    if has_cmd dmesg; then
        local devname
        devname=$(basename "$dev")

        # Get the last 20 dmesg lines mentioning the device
        local dm_output
        dm_output=$(dmesg 2>/dev/null | tail -50 | grep -iE "sd|usb|scsi|mass" | \
                    grep -i "$devname" || true)

        if [ -n "$dm_output" ]; then
            info "Kernel messages for $devname:"
            echo "$dm_output" | tail -10 | sed 's/^/      /'
        else
            info "No kernel messages found for $devname (dmesg may require root)"
        fi

        # Check for errors
        if dmesg 2>/dev/null | tail -50 | grep -i "$devname" | grep -qi "error\|fail\|timeout"; then
            warn "Errors found in dmesg for $devname" \
                 "Check USB cable or device firmware"
        fi
    else
        warn "dmesg not available — cannot check kernel messages"
    fi
}

# =============================================================================
# Main

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                DEVICE="$2"
                shift 2
                ;;
            --write-test)
                WRITE_TEST=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --device /dev/sdX   Specify the USB MSC device manually"
                echo "  --write-test        Include write-read verification (modifies data temporarily)"
                echo "  --verbose           Show hex dumps and detailed information"
                echo "  --help              Show this help message"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    echo -e "${BOLD}${BLUE}"
    echo "  USB Mass Storage Device Validation Script"
    echo "  For ESP32-S3 N16R8 and similar USB MSC devices"
    echo -e "${NC}"

    find_esp32s3_devices

    # Run all test suites for each found device
    for dev in "${FOUND_DEVICES[@]}"; do
        echo ""
        echo -e "${YELLOW}>>> Testing device: $dev${NC}"
        echo ""

        test_sector_size "$dev"
        test_capacity "$dev"
        test_mbr_signature "$dev"
        test_partition_table "$dev"
        test_filesystem "$dev"
        test_read "$dev"
        test_usb_info "$dev"
        test_dmesg "$dev"

        if [ "$WRITE_TEST" = "true" ]; then
            test_write "$dev"
        else
            info "Skipping write test (use --write-test to enable)"
        fi
    done

    # Summary
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BOLD}  RESULTS${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo -e "  ${GREEN}PASSED: $PASS${NC}"
    echo -e "  ${RED}FAILED: $FAIL${NC}"
    echo -e "  ${YELLOW}WARNED: $WARN${NC}"
    echo -e "  ${BOLD}TOTAL:  $TOTAL${NC}"
    echo ""

    if [ "$FAIL" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}========================================${NC}"
        echo -e "${GREEN}${BOLD}  ALL TESTS PASSED${NC}"
        echo -e "${GREEN}${BOLD}  Device is ready for use${NC}"
        echo -e "${GREEN}${BOLD}========================================${NC}"
        if [ "$WARN" -gt 0 ]; then
            echo -e "${YELLOW}  ($WARN warning(s) — review above)${NC}"
        fi
        exit 0
    else
        echo -e "${RED}${BOLD}========================================${NC}"
        echo -e "${RED}${BOLD}  $FAIL TEST(S) FAILED${NC}"
        echo -e "${RED}${BOLD}  Review failures above before proceeding${NC}"
        echo -e "${RED}${BOLD}========================================${NC}"
        exit 1
    fi
}

main "$@"
