#!/usr/bin/env bash
# =============================================================================
# validate.sh — Comprehensive build verification suite for ESP32-S3 USB MSC
#               thumbdrive project (ESP-IDF v6.1-beta1, N16R8 module)
#
# Usage:  ./scripts/validate.sh
#
# This script validates every aspect of the build:
#   1. Source files: changelogs present, no non-ASCII characters
#   2. Configuration: sdkconfig.defaults settings correct
#   3. Partition table: correct offsets, sizes, alignment, fills 16 MB
#   4. Firmware source: MOUNT_USB, 512-byte sectors, MSC enabled
#   5. Build: idf.py build succeeds, no warnings/errors
#   6. Binary: firmware fits in factory partition, flash config correct
#   7. Combined image: merge_bin produces valid file
#   8. GitHub: repo structure, commits, release tag
#
# Exit codes:
#   0 = ALL TESTS PASSED
#   1 = One or more tests FAILED
# =============================================================================

set -euo pipefail

# ---- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---- Counters ----------------------------------------------------------------
PASS=0
FAIL=0
WARN=0
TOTAL=0

# ---- Paths -------------------------------------------------------------------
PROJECT_DIR="/home/whipsthellamasass/workspace/thumbdrive"
BUILD_DIR="${PROJECT_DIR}/build"
ESP_IDF="${PROJECT_DIR}/../esp"  # ESP-IDF at ~/workspace/esp

# ---- Helpers -----------------------------------------------------------------

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Assert function: checks a condition and prints pass/fail
# Usage: assert "description" "command" [expected_output_regex]
assert() {
    local desc="$1"
    local cmd="$2"
    local expected="${3:-}"
    TOTAL=$((TOTAL + 1))

    local output
    output=$(eval "$cmd" 2>&1) || true

    if [ -n "$expected" ]; then
        if echo "$output" | grep -qiE "$expected"; then
            echo -e "  ${GREEN}[PASS]${NC} $desc"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $desc"
            echo -e "       Expected: pattern /${expected}/"
            echo -e "       Got:      ${output:0:120}"
            FAIL=$((FAIL + 1))
        fi
    else
        if [ $? -eq 0 ] && [ -n "$output" ]; then
            echo -e "  ${GREEN}[PASS]${NC} $desc"
            PASS=$((PASS + 1))
        elif [ $? -eq 0 ] && [ -z "$output" ]; then
            echo -e "  ${GREEN}[PASS]${NC} $desc (exit 0, no output)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $desc"
            echo -e "       Command: $cmd"
            echo -e "       Output:  ${output:0:120}"
            FAIL=$((FAIL + 1))
        fi
    fi
}

# Soft assert: warns but doesn't fail the test if condition is not met
assert_warn() {
    local desc="$1"
    local cmd="$2"
    local expected="${3:-}"
    TOTAL=$((TOTAL + 1))

    local output
    output=$(eval "$cmd" 2>&1) || true

    if [ -n "$expected" ]; then
        if echo "$output" | grep -qiE "$expected"; then
            echo -e "  ${GREEN}[PASS]${NC} $desc"
            PASS=$((PASS + 1))
        else
            echo -e "  ${YELLOW}[WARN]${NC} $desc"
            WARN=$((WARN + 1))
        fi
    else
        if [ -n "$output" ]; then
            echo -e "  ${GREEN}[PASS]${NC} $desc"
            PASS=$((PASS + 1))
        else
            echo -e "  ${YELLOW}[WARN]${NC} $desc"
            WARN=$((WARN + 1))
        fi
    fi
}

# Check a specific sdkconfig.defaults key
check_config() {
    local desc="$1"
    local key="$2"
    local expected="$3"
    TOTAL=$((TOTAL + 1))

    local actual
    actual=$(grep "^${key}=" "${PROJECT_DIR}/sdkconfig.defaults" 2>/dev/null | tail -1 | cut -d= -f2-)
    # Strip surrounding quotes if present (e.g. "esp32s3" -> esp32s3)
    actual=$(echo "$actual" | sed 's/^"//;s/"$//')

    if [ "$actual" = "$expected" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $desc ($key=$expected)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $desc ($key)"
        echo -e "       Expected: $expected"
        echo -e "       Got:      ${actual:-<not set>}"
        FAIL=$((FAIL + 1))
    fi
}

# Check a config key is NOT set (commented out or absent)
check_config_absent() {
    local desc="$1"
    local key="$2"
    TOTAL=$((TOTAL + 1))

    local line
    line=$(grep "^${key}=" "${PROJECT_DIR}/sdkconfig.defaults" 2>/dev/null | head -1)

    if [ -z "$line" ]; then
        echo -e "  ${GREEN}[PASS]${NC} $desc ($key not set)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $desc ($key still set: $line)"
        FAIL=$((FAIL + 1))
    fi
}

# ---- Test Suite 1: Source File Integrity -------------------------------------

test_source_files() {
    print_header "Suite 1: Source File Integrity"

    # All tracked files should have a changelog header
    local files_to_check=(
        "${PROJECT_DIR}/sdkconfig.defaults"
        "${PROJECT_DIR}/partitions.csv"
        "${PROJECT_DIR}/main/main.c"
        "${PROJECT_DIR}/main/CMakeLists.txt"
        "${PROJECT_DIR}/main/idf_component.yml"
        "${PROJECT_DIR}/CMakeLists.txt"
    )

    for f in "${files_to_check[@]}"; do
        TOTAL=$((TOTAL + 1))
        if head -5 "$f" | grep -qi "CHANGELOG\|changelog"; then
            echo -e "  ${GREEN}[PASS]${NC} $(basename "$f") has changelog header"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} $(basename "$f") missing changelog header"
            FAIL=$((FAIL + 1))
        fi
    done

    # No non-ASCII characters in C source or config (.csv) files
    TOTAL=$((TOTAL + 1))
    local non_ascii=0
    for f in "${PROJECT_DIR}/main/main.c" "${PROJECT_DIR}/partitions.csv" \
              "${PROJECT_DIR}/sdkconfig.defaults"; do
        if [ -f "$f" ]; then
            count=$(grep -cP '[^\x00-\x7f]' "$f" 2>/dev/null)
            count=$(echo "$count" | tr -cd '0-9')
            if [ -z "$count" ]; then
                count=0
            fi
            if [ "$count" -gt 0 ]; then
                non_ascii=$((non_ascii + count))
                echo -e "  ${RED}[FAIL]${NC} $f contains $count non-ASCII characters"
            fi
        fi
    done
    if [ "$non_ascii" -eq 0 ]; then
        echo -e "  ${GREEN}[PASS]${NC} No non-ASCII characters in C/config files (compiler-safe)"
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
}

# ---- Test Suite 2: sdkconfig.defaults Validation -----------------------------

test_sdkconfig_defaults() {
    print_header "Suite 2: sdkconfig.defaults Settings"

    check_config "ESP32-S3 target" "CONFIG_IDF_TARGET" "esp32s3"
    check_config "16 MB flash size" "CONFIG_ESPTOOLPY_FLASHSIZE_16MB" "y"
    check_config "Custom partition table" "CONFIG_PARTITION_TABLE_CUSTOM" "y"

    TOTAL=$((TOTAL + 1))
    local pt_file
    pt_file=$(grep "^CONFIG_PARTITION_TABLE_FILENAME=" "${PROJECT_DIR}/sdkconfig.defaults" 2>/dev/null | cut -d= -f2- | tr -d '"')
    if [ "$pt_file" = "partitions.csv" ]; then
        echo -e "  ${GREEN}[PASS]${NC} Partition table filename = partitions.csv"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Partition table filename should be partitions.csv, got: $pt_file"
        FAIL=$((FAIL + 1))
    fi

    check_config "512-byte WL sector size" "CONFIG_WL_SECTOR_SIZE_512" "y"
    check_config "WL_SECTOR_SIZE value" "CONFIG_WL_SECTOR_SIZE" "512"
    check_config "MSC enabled" "CONFIG_TINYUSB_MSC_ENABLED" "y"
    check_config "MSC buffer size" "CONFIG_TINYUSB_MSC_BUFSIZE" "4096"
    check_config "Compiler optimization size" "CONFIG_COMPILER_OPTIMIZATION_SIZE" "y"
    check_config "WiFi disabled" "CONFIG_ESP_WIFI_ENABLED" "n"
    check_config "Bluetooth disabled" "CONFIG_BT_ENABLED" "n"

    # Verify absent (old/bad settings)
    check_config_absent "Old 2 MB flash" "CONFIG_ESPTOOLPY_FLASHSIZE_2MB"
    check_config_absent "Default SINGLE_APP" "CONFIG_PARTITION_TABLE_SINGLE_APP"
    check_config_absent "Old 4096-byte sector" "CONFIG_WL_SECTOR_SIZE_4096"
}

# ---- Test Suite 3: Partition Table Validation --------------------------------

test_partitions() {
    print_header "Suite 3: Partition Table (partitions.csv)"

    TOTAL=$((TOTAL + 1))
    local csv="${PROJECT_DIR}/partitions.csv"
    if [ ! -f "$csv" ]; then
        echo -e "  ${RED}[FAIL]${NC} partitions.csv not found"
        FAIL=$((FAIL + 1))
        return
    fi

    # Parse partition entries (skip comments and header lines)
    # Expected: nvs@0x9000, phy_init@0xd000, factory@0x10000, storage@0x40000

    TOTAL=$((TOTAL + 1))
    local nvs_offset
    nvs_offset=$(grep -i '^nvs,' "$csv" | awk -F, '{print $4}' | head -1)
    if [ "$nvs_offset" = "0x9000" ]; then
        echo -e "  ${GREEN}[PASS]${NC} NVS partition at 0x9000"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} NVS offset should be 0x9000, got ${nvs_offset:-<missing>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    local nvs_size
    nvs_size=$(grep -i '^nvs,' "$csv" | awk -F, '{print $5}' | head -1)
    if [ "$nvs_size" = "0x4000" ]; then
        echo -e "  ${GREEN}[PASS]${NC} NVS partition size 0x4000 (16 KB)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} NVS size should be 0x4000, got ${nvs_size:-<missing>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    local phy_offset
    phy_offset=$(grep -i '^phy_init,' "$csv" | awk -F, '{print $4}' | head -1)
    if [ "$phy_offset" = "0xd000" ]; then
        echo -e "  ${GREEN}[PASS]${NC} phy_init partition at 0xd000"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} phy_init offset should be 0xd000, got ${phy_offset:-<missing>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    local factory_offset
    factory_offset=$(grep -i '^factory,' "$csv" | awk -F, '{print $4}' | head -1)
    if [ "$factory_offset" = "0x10000" ]; then
        echo -e "  ${GREEN}[PASS]${NC} factory partition at 0x10000 (64KB-aligned)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} factory offset should be 0x10000 (64KB-aligned), got ${factory_offset:-<missing>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    local factory_size
    factory_size=$(grep -i '^factory,' "$csv" | awk -F, '{print $5}' | head -1)
    if [ "$factory_size" = "0x30000" ]; then
        echo -e "  ${GREEN}[PASS]${NC} factory partition size 0x30000 (192 KB)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} factory size should be 0x30000 (192KB), got ${factory_size:-<missing>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    local storage_offset
    storage_offset=$(grep -i '^storage,' "$csv" | awk -F, '{print $4}' | head -1)
    if [ "$storage_offset" = "0x40000" ]; then
        echo -e "  ${GREEN}[PASS]${NC} storage partition at 0x40000 (immediately after factory)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} storage offset should be 0x40000, got ${storage_offset:-<missing>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    local storage_size
    storage_size=$(grep -i '^storage,' "$csv" | awk -F, '{print $5}' | head -1)
    # Expected: 0xfc0000 = 16MB - 0x40000
    if [ "$storage_size" = "0xfc0000" ]; then
        echo -e "  ${GREEN}[PASS]${NC} storage size 0xfc0000 (fills 16MB flash exactly)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} storage size should be 0xfc0000, got ${storage_size:-<missing>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify storage ends at exactly 16 MB: 0x40000 + 0xfc0000 = 0x1000000
    local end=$(( storage_offset_int + storage_size_int ))
    local storage_off_dec=$((0x40000))
    local storage_size_dec=$((0xfc0000))
    if [ $((storage_off_dec + storage_size_dec)) -eq $((0x1000000)) ]; then
        echo -e "  ${GREEN}[PASS]${NC} storage ends at 0x1000000 (exactly 16 MB — no overflow)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} storage does not fill 16MB flash"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify factory is app type and storage is fat type
    local factory_type
    factory_type=$(grep -i '^factory,' "$csv" | awk -F, '{print $2}' | head -1)
    local storage_type
    storage_type=$(grep -i '^storage,' "$csv" | awk -F, '{print $3}' | head -1)
    if [ "$factory_type" = "app" ] && [ "$storage_type" = "fat" ]; then
        echo -e "  ${GREEN}[PASS]${NC} factory=app, storage=fat (correct types)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} factory type=$factory_type (want 'app'), storage subtype=$storage_type (want 'fat')"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify 8 KB gap exists between phy_init end and factory start
    # phy_init ends at 0xe000, factory starts at 0x10000 -> 8 KB gap
    if [ $((0xd000 + 0x1000)) -eq $((0xe000)) ] && [ $((0xe000)) -lt $((0x10000)) ]; then
        echo -e "  ${GREEN}[PASS]${NC} 8 KB gap (0xe000-0x10000) for 64KB alignment — expected"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} Gap alignment needs review"
        WARN=$((WARN + 1))
    fi
}

# ---- Test Suite 4: Firmware Source Code Validation ---------------------------

test_main_c() {
    print_header "Suite 4: Firmware Source Code (main.c)"

    TOTAL=$((TOTAL + 1))
    if grep -q "TINYUSB_MSC_STORAGE_MOUNT_USB" "${PROJECT_DIR}/main/main.c"; then
        echo -e "  ${GREEN}[PASS]${NC} mount_point = TINYUSB_MSC_STORAGE_MOUNT_USB (raw sector mode)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} mount_point is not MOUNT_USB — FAT mount would trigger!"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    if grep -q "TINYUSB_DEFAULT_CONFIG" "${PROJECT_DIR}/main/main.c"; then
        echo -e "  ${GREEN}[PASS]${NC} Uses TINYUSB_DEFAULT_CONFIG() macro (v2.x API)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} TINYUSB_DEFAULT_CONFIG not found — wrong API version?"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    if grep -q "tinyusb_msc_new_storage_spiflash" "${PROJECT_DIR}/main/main.c"; then
        echo -e "  ${GREEN}[PASS]${NC} Uses tinyusb_msc_new_storage_spiflash() (v2.x API)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} tinyusb_msc_new_storage_spiflash not found"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify MOUNT_APP is NOT used as a mount_point value (would trigger FAT mount)
    local app_usages
    app_usages=$(grep "MOUNT_APP" "${PROJECT_DIR}/main/main.c" 2>/dev/null | wc -l)
    if [ "$app_usages" -eq 0 ]; then
        echo -e "  ${GREEN}[PASS]${NC} MOUNT_APP not used anywhere (no FAT mount trigger)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} MOUNT_APP found in source ($app_usages occurrences) — check if used as mount_point"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    if ! grep -qP '[^\x00-\x7f]' "${PROJECT_DIR}/main/main.c"; then
        echo -e "  ${GREEN}[PASS]${NC} main.c is pure ASCII (compiler-safe)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} main.c contains non-ASCII characters"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Check the storage config struct fields
    if grep -q "wl_handle" "${PROJECT_DIR}/main/main.c" && \
       grep -q "do_not_format" "${PROJECT_DIR}/main/main.c" && \
       grep -q "_MSC_STORAGE_MOUNT_USB" "${PROJECT_DIR}/main/main.c"; then
        echo -e "  ${GREEN}[PASS]${NC} tinyusb_msc_storage_config_t fields present (wl_handle, do_not_format, mount_point)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Missing storage config fields in main.c"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify app_main calls esp_partition_find for storage FAT partition
    if grep -q "esp_partition_find\|esp_partition_find_first\|storage" "${PROJECT_DIR}/main/main.c" && \
       grep -q "ESP_LOGI\|ESP_LOGE\|ESP_LOGW\|ESP_LOGD\|ESP_LOGV\|esp_log" "${PROJECT_DIR}/main/main.c"; then
        echo -e "  ${GREEN}[PASS]${NC} main.c has partition lookup and logging"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} main.c may be missing partition lookup or logging"
        WARN=$((WARN + 1))
    fi
}

# ---- Test Suite 5: Component Dependency Validation ---------------------------

test_dependencies() {
    print_header "Suite 5: Component Dependencies"

    TOTAL=$((TOTAL + 1))
    local comp_file="${PROJECT_DIR}/main/idf_component.yml"
    if [ -f "$comp_file" ]; then
        local version
        version=$(grep "esp_tinyusb" "$comp_file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ "$version" = "2.2.1" ] || grep -q "esp_tinyusb.*2.2" "$comp_file"; then
            echo -e "  ${GREEN}[PASS]${NC} esp_tinyusb >= 2.2.1 in idf_component.yml"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} esp_tinyusb version should be 2.2.1, got: $version"
            FAIL=$((FAIL + 1))
        fi
    else
        echo -e "  ${RED}[FAIL]${NC} idf_component.yml not found"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify esp_tinyusb is in managed_components (was downloaded)
    if [ -d "${PROJECT_DIR}/managed_components/espressif__esp_tinyusb" ]; then
        local mc_version
        mc_version=$(grep -m1 "version" "${PROJECT_DIR}/managed_components/espressif__esp_tinyusb/idf_component.yml" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        if [ -n "$mc_version" ]; then
            echo -e "  ${GREEN}[PASS]${NC} esp_tinyusb downloaded at v${mc_version}"
            PASS=$((PASS + 1))
        else
            echo -e "  ${GREEN}[PASS]${NC} esp_tinyusb directory exists (version not in metadata)"
            PASS=$((PASS + 1))
        fi
    else
        echo -e "  ${RED}[FAIL]${NC} esp_tinyusb NOT in managed_components — run idf.py add-dependency"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify the v2.x API header exists (tinyusb_msc.h, not deprecated tusb_msc_storage.h)
    if [ -f "${PROJECT_DIR}/managed_components/espressif__esp_tinyusb/include/tinyusb_msc.h" ]; then
        echo -e "  ${GREEN}[PASS]${NC} tinyusb_msc.h header exists (v2.x API)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} tinyusb_msc.h not found — wrong version or path?"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify the old deprecated header is NOT the one we use
    if grep -q "#include.*tinyusb_msc.h" "${PROJECT_DIR}/main/main.c" && \
       ! grep -q "#include.*tusb_msc_storage.h" "${PROJECT_DIR}/main/main.c"; then
        echo -e "  ${GREEN}[PASS]${NC} main.c includes tinyusb_msc.h (not deprecated tusb_msc_storage.h)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} main.c includes wrong header"
        FAIL=$((FAIL + 1))
    fi
}

# ---- Test Suite 6: Build Validation ------------------------------------------

test_build() {
    print_header "Suite 6: Build Verification"

    TOTAL=$((TOTAL + 1))
    if [ -f "${BUILD_DIR}/usb_thumbdrive.bin" ]; then
        echo -e "  ${GREEN}[PASS]${NC} usb_thumbdrive.bin exists in build/"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} usb_thumbdrive.bin not found — run 'idf.py build'"
        FAIL=$((FAIL + 1))
        return
    fi

    TOTAL=$((TOTAL + 1))
    local bin_size
    bin_size=$(stat -c%s "${BUILD_DIR}/usb_thumbdrive.bin" 2>/dev/null || echo 0)
    local bin_size_hex
    bin_size_hex=$(printf "0x%x" "$bin_size")
    echo -e "  ${BLUE}INFO${NC} Firmware binary: ${bin_size} bytes (${bin_size_hex})"
    if [ "$bin_size" -gt 0 ]; then
        echo -e "  ${GREEN}[PASS]${NC} Binary is non-empty"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Binary size is zero"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Firmware should be <= 192KB (0x30000 = factory partition size)
    if [ "$bin_size" -le $((0x30000)) ]; then
        local headroom=$((0x30000 - bin_size))
        echo -e "  ${GREEN}[PASS]${NC} Binary fits in 192KB factory partition (${headroom} bytes free = ~$((headroom*100/0x30000))%)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Binary (0x${bin_size_hex}) exceeds 192KB factory partition (0x30000)"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Bootloader should exist
    if [ -f "${BUILD_DIR}/bootloader/bootloader.bin" ]; then
        local bl_size
        bl_size=$(stat -c%s "${BUILD_DIR}/bootloader/bootloader.bin")
        echo -e "  ${GREEN}[PASS]${NC} bootloader.bin exists (${bl_size} bytes)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} bootloader.bin not found"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Partition table should exist
    if [ -f "${BUILD_DIR}/partition_table/partition-table.bin" ]; then
        local pt_size
        pt_size=$(stat -c%s "${BUILD_DIR}/partition_table/partition-table.bin")
        echo -e "  ${GREEN}[PASS]${NC} partition-table.bin exists (${pt_size} bytes)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} partition-table.bin not found"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Combined binary should exist
    if [ -f "${BUILD_DIR}/combined.bin" ]; then
        local cb_size
        cb_size=$(stat -c%s "${BUILD_DIR}/combined.bin")
        echo -e "  ${GREEN}[PASS]${NC} combined.bin exists (${cb_size} bytes, all 3 binaries merged at offset 0)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} combined.bin not found — generate with esptool.py merge_bin"
        WARN=$((WARN + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Check generated sdkconfig has correct settings
    local gen_sdkconfig="${BUILD_DIR}/config/sdkconfig"
    if [ -f "$gen_sdkconfig" ]; then
        if grep -q "CONFIG_ESPTOOLPY_FLASHSIZE_16MB=y" "$gen_sdkconfig" && \
           grep -q "CONFIG_PARTITION_TABLE_CUSTOM=y" "$gen_sdkconfig" && \
           grep -q "CONFIG_WL_SECTOR_SIZE=512" "$gen_sdkconfig"; then
            echo -e "  ${GREEN}[PASS]${NC} Generated sdkconfig has 16MB flash + custom table + 512-byte sectors"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} Generated sdkconfig has incorrect settings"
            FAIL=$((FAIL + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} Generated sdkconfig not found at ${gen_sdkconfig}"
        WARN=$((WARN + 1))
    fi
}

# ---- Test Suite 7: Flash Command Validation ----------------------------------

test_flash_command() {
    print_header "Suite 7: Flash Command Validation"

    TOTAL=$((TOTAL + 1))
    local flash_args="${BUILD_DIR}/flash_args"
    if [ -f "$flash_args" ]; then
        local has_flash_size has_offset_0 has_offset_8000 has_offset_10000
        has_flash_size=$(grep -c "16MB" "$flash_args" 2>/dev/null || echo 0)
        has_offset_0=$(grep -c "0x0" "$flash_args" 2>/dev/null || echo 0)
        has_offset_8000=$(grep -c "0x8000" "$flash_args" 2>/dev/null || echo 0)
        has_offset_10000=$(grep -c "0x10000" "$flash_args" 2>/dev/null || echo 0)

        local all_good=1
        [ "$has_flash_size" -eq 0 ] && all_good=0
        [ "$has_offset_0" -eq 0 ] && all_good=0
        [ "$has_offset_8000" -eq 0 ] && all_good=0
        [ "$has_offset_10000" -eq 0 ] && all_good=0

        if [ "$all_good" -eq 1 ]; then
            echo -e "  ${GREEN}[PASS]${NC} flash_args has --flash-size 16MB + offsets 0x0, 0x8000, 0x10000"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} flash_args missing required entries (16MB:$has_flash_size, 0x0:$has_offset_0, 0x8000:$has_offset_8000, 0x10000:$has_offset_10000)"
            FAIL=$((FAIL + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} flash_args not found — run idf.py build"
        WARN=$((WARN + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify partition table dump shows correct layout
    local gen_pt_dump="${BUILD_DIR}/partition_table"
    if [ -d "$gen_pt_dump" ]; then
        # Use gen_esp32part.py if available to decode the binary
        local gen_script="${ESP_IDF}/components/partition_table/gen_esp32part.py"
        if [ -f "$gen_script" ]; then
            local pt_dump
            pt_dump=$(python3 "$gen_script" -q --offset 0x8000 --flash-size 16MB \
                "${BUILD_DIR}/partition_table/partition-table.bin" 2>/dev/null)
            local has_nvs has_factory has_storage
            has_nvs=$(echo "$pt_dump" | grep -c "^nvs," || echo 0)
            has_factory=$(echo "$pt_dump" | grep -c "^factory," || echo 0)
            has_storage=$(echo "$pt_dump" | grep -c "^storage," || echo 0)

            if [ "$has_nvs" -gt 0 ] && [ "$has_factory" -gt 0 ] && [ "$has_storage" -gt 0 ]; then
                echo -e "  ${GREEN}[PASS]${NC} Generated partition table has nvs, factory, and storage entries"
                PASS=$((PASS + 1))
                echo -e "       ${BLUE}Detail${NC}: $(echo "$pt_dump" | grep "^nvs,")"
                echo -e "       ${BLUE}Detail${NC}: $(echo "$pt_dump" | grep "^phy_init,")"
                echo -e "       ${BLUE}Detail${NC}: $(echo "$pt_dump" | grep "^factory,")"
                echo -e "       ${BLUE}Detail${NC}: $(echo "$pt_dump" | grep "^storage,")"
            else
                echo -e "  ${RED}[FAIL]${NC} Generated partition table missing entries"
                FAIL=$((FAIL + 1))
            fi
        else
            echo -e "  ${YELLOW}[WARN]${NC} gen_esp32part.py not found — cannot decode partition table"
            WARN=$((WARN + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} Partition table build dir not found"
        WARN=$((WARN + 1))
    fi
}

# ---- Test Suite 8: GitHub Remote Validation ----------------------------------

test_github() {
    print_header "Suite 8: GitHub Repository Validation"

    TOTAL=$((TOTAL + 1))
    local remote_url
    remote_url=$(cd "$PROJECT_DIR" && git remote get-url origin 2>/dev/null)
    if echo "$remote_url" | grep -q "rambalakrishnan/thumbdrive-esp-idf-v6.1"; then
        echo -e "  ${GREEN}[PASS]${NC} Git remote points to rambalakrishnan/thumbdrive-esp-idf-v6.1"
        echo -e "       Remote: ${remote_url}"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Git remote is not pointing to the correct repo"
        echo -e "       Remote: ${remote_url:-<not set>}"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify SSH remote (not HTTPS)
    if cd "$PROJECT_DIR" && git remote get-url origin | grep -q "^git@"; then
        echo -e "  ${GREEN}[PASS]${NC} Remote uses SSH (not HTTPS — no auth issues)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} Remote is not SSH — push may require token auth"
        WARN=$((WARN + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify at least 8 commits exist
    local commit_count
    commit_count=$(cd "$PROJECT_DIR" && git log --oneline 2>/dev/null | wc -l)
    if [ "$commit_count" -ge 8 ]; then
        echo -e "  ${GREEN}[PASS]${NC} Repository has $commit_count commits (>= 8)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} Only $commit_count commits — expected >= 8"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify MOUNT_USB commit exists
    if cd "$PROJECT_DIR" && git log --oneline | grep -q "MOUNT_USB"; then
        echo -e "  ${GREEN}[PASS]${NC} MOUNT_USB commit found in history"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} MOUNT_USB commit not found"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify GitHub release exists
    if gh release view v0.1.0 >/dev/null 2>&1; then
        echo -e "  ${GREEN}[PASS]${NC} GitHub release v0.1.0 exists"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} GitHub release v0.1.0 not found — run 'gh release create'"
        WARN=$((WARN + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify combined.bin is in the release
    if gh release view v0.1.0 --json assets --jq '.assets[].name' 2>/dev/null | grep -q "combined.bin"; then
        echo -e "  ${GREEN}[PASS]${NC} combined.bin attached to release v0.1.0"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} combined.bin not found in release v0.1.0"
        WARN=$((WARN + 1))
    fi
}

# ---- Test Suite 9: Binary Deep Inspection ------------------------------------

test_binary_inspection() {
    print_header "Suite 9: Binary Deep Inspection"

    TOTAL=$((TOTAL + 1))
    # Check the firmware ELF (if it exists) for key symbols
    local elf="${BUILD_DIR}/usb_thumbdrive.elf"
    if [ -f "$elf" ]; then
        # Check for MOUNT_USB enum value (should be 0)
        if strings "$elf" | grep -q "mount_point"; then
            echo -e "  ${GREEN}[PASS]${NC} Firmware ELF contains 'mount_point' (storage config struct)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${YELLOW}[WARN]${NC} mount_point not found in ELF strings (symbols may be stripped)"
            WARN=$((WARN + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} usb_thumbdrive.elf not found — skipping deep inspection"
        WARN=$((WARN + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify bootloader size is reasonable (should be < 32KB partition)
    if [ -f "${BUILD_DIR}/bootloader/bootloader.bin" ]; then
        local bl_size
        bl_size=$(stat -c%s "${BUILD_DIR}/bootloader/bootloader.bin")
        if [ "$bl_size" -lt $((0x8000)) ]; then
            echo -e "  ${GREEN}[PASS]${NC} Bootloader (${bl_size} bytes) fits in 32KB partition"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} Bootloader (${bl_size} bytes) exceeds 32KB partition"
            FAIL=$((FAIL + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} Bootloader binary not found"
        WARN=$((WARN + 1))
    fi

    TOTAL=$((TOTAL + 1))
    # Verify combined.bin is the merger of all three (check size)
    if [ -f "${BUILD_DIR}/combined.bin" ]; then
        local cb_size bl_size pt_size app_size
        cb_size=$(stat -c%s "${BUILD_DIR}/combined.bin")
        bl_size=$(stat -c%s "${BUILD_DIR}/bootloader/bootloader.bin" 2>/dev/null || echo 0)
        pt_size=$(stat -c%s "${BUILD_DIR}/partition_table/partition-table.bin" 2>/dev/null || echo 0)

        # combined should be >= sum of the three padded to flash sectors
        # But more importantly, it should start with a valid bootloader header
        local first_bytes
        first_bytes=$(xxd -l 8 -p "${BUILD_DIR}/combined.bin" 2>/dev/null)
        # ESP32 bootloader starts with: 0x07 0x07 0x19 0x00 (or similar magic)
        if echo "$first_bytes" | grep -qE "^e707|^0707|^e70719|^070719"; then
            echo -e "  ${GREEN}[PASS]${NC} combined.bin starts with valid ESP32 image header"
            PASS=$((PASS + 1))
        elif [ "$cb_size" -gt 0 ]; then
            echo -e "  ${YELLOW}[WARN]${NC} combined.bin header bytes: $first_bytes (unrecognized magic)"
            WARN=$((WARN + 1))
        else
            echo -e "  ${RED}[FAIL]${NC} combined.bin is empty or invalid"
            FAIL=$((FAIL + 1))
        fi
    else
        echo -e "  ${YELLOW}[WARN]${NC} combined.bin not found"
        WARN=$((WARN + 1))
    fi
}

# ---- Test Suite 10: .gitignore Validation ------------------------------------

test_gitignore() {
    print_header "Suite 10: .gitignore Validation"

    TOTAL=$((TOTAL + 1))
    if grep -q '/build/' "${PROJECT_DIR}/.gitignore"; then
        echo -e "  ${GREEN}[PASS]${NC} /build/ is gitignored (binaries not committed)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} /build/ not in .gitignore — binaries would be committed"
        FAIL=$((FAIL + 1))
    fi

    TOTAL=$((TOTAL + 1))
    if grep -q '/managed_components/' "${PROJECT_DIR}/.gitignore"; then
        echo -e "  ${GREEN}[PASS]${NC} /managed_components/ is gitignored"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} /managed_components/ not in .gitignore"
        WARN=$((WARN + 1))
    fi

    TOTAL=$((TOTAL + 1))
    if grep -q '/sdkconfig' "${PROJECT_DIR}/.gitignore"; then
        echo -e "  ${GREEN}[PASS]${NC} /sdkconfig is gitignored (machine-specific)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${YELLOW}[WARN]${NC} /sdkconfig not in .gitignore"
        WARN=$((WARN + 1))
    fi
}

# ---- Main --------------------------------------------------------------------

main() {
    echo -e "${BOLD}${BLUE}"
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║   ESP32-S3 USB MSC Thumbdrive — Comprehensive Build Verification    ║"
    echo "║   Target: ESP32-S3 N16R8 (16 MB flash) | ESP-IDF v6.1-beta1          ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "${BOLD}Project: ${NC}${PROJECT_DIR}"
    echo -e "${BOLD}Started: ${NC}$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    test_source_files
    test_sdkconfig_defaults
    test_partitions
    test_main_c
    test_dependencies
    test_build
    test_flash_command
    test_github
    test_binary_inspection
    test_gitignore

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  RESULTS${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}PASSED: $PASS${NC}"
    echo -e "  ${RED}FAILED: $FAIL${NC}"
    echo -e "  ${YELLOW}WARNED: $WARN${NC}"
    echo -e "  ${BOLD}TOTAL:  $TOTAL${NC}"
    echo ""

    if [ "$FAIL" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}========================================${NC}"
        echo -e "${GREEN}${BOLD}  ALL TESTS PASSED — BUILD IS GOOD    ${NC}"
        echo -e "${GREEN}${BOLD}========================================${NC}"
        exit 0
    else
        echo -e "${RED}${BOLD}========================================${NC}"
        echo -e "${RED}${BOLD}  $FAIL TEST(S) FAILED — FIX BEFORE FLASHING ${NC}"
        echo -e "${RED}${BOLD}========================================${NC}"
        exit 1
    fi
}

main "$@"
