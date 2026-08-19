/*******************************************************************************
 * CHANGELOG
 * -----------------------------------------------------------------------------
 * [v2.x-api-migration] 2026-08-18  s.ram.balakrishnan@gmail.com
 *   - Complete rewrite of app_main() for the esp_tinyusb v2.2.1 API.
 *
 *   The original code targeted a pre-1.4 esp_tinyusb API that used:
 *     - tinyusb_msc_slots_config_t        (type no longer exists)
 *     - tusb_msc_storage_init()            (function no longer exists)
 *     - tusb_msc_storage.h header          (deprecated wrapper, emits #warning)
 *
 *   The v2.x API (tinyusb_msc.h) uses an opaque handle, a two-struct config
 *   (storage_config + fatfs_config), and explicit mount-point management:
 *
 *     - tinyusb_msc_storage_handle_t      (opaque handle, not NULL-able)
 *     - tinyusb_msc_storage_config_t      (replaces tinyusb_msc_spiflash_config_t)
 *     - tinyusb_msc_new_storage_spiflash() (replaces tusb_msc_storage_init)
 *     - tinyusb_msc_set_storage_mount_point() (mount/unmount to APP or USB)
 *
 *   Includes updated:
 *     - "tinyusb.h"            (was already included)
 *     - "tinyusb_default_config.h"  (NEW -- provides TINYUSB_DEFAULT_CONFIG())
 *     - "tinyusb_msc.h"        (NEW -- replaces deprecated tusb_msc_storage.h)
 *
 * [usb-boot-raw-msc-mode] 2026-08-18  s.ram.balakrishnan@gmail.com
 *   - Changed mount_point from MOUNT_APP to MOUNT_USB.
 *
 *     In tinyusb_msc_new_storage_spiflash(), the FAT filesystem is only mounted
 *     (and auto-formatted if blank) when config->mount_point == MOUNT_APP:
 *
 *       if (config->mount_point == TINYUSB_MSC_STORAGE_MOUNT_APP) {
 *           ret = msc_storage_mount(storage);  // <- this calls vfs_fat_mount -> f_mkfs() if blank
 *       }
 *
 *     With MOUNT_USB, the FAT layer is never touched.  The MSC class callbacks
 *     (tud_msc_read10_cb / tud_msc_write10_cb) route directly through
 *     storage_spiflash_sector_read() -> wl_read() and
 *     storage_spiflash_sector_write() -> wl_erase_range() + wl_write(),
 *     presenting raw sectors to the USB host.
 *
 *     Rationale: This device is a USB boot medium (MBR + FAT32 created on a
 *     Linux host, not by the firmware).  Auto-format / FAT mount on the
 *     firmware side is undesirable:
 *       *   The MBR at sector 0 would be mistaken for a non-FAT filesystem
 *         and overwritten by f_mkfs().
 *       *   No application-side file I/O is needed -- the firmware only serves
 *         raw blocks.
 *
 *     Wear-levelling remains active (wl_read/wl_write), providing transparent
 *     endurance management on the storage partition.  The WL metadata lives
 *     at the END of the flash partition (confirmed in WL_Flash::config()),
 *     so data at the beginning (sector 0 = MBR) is preserved across wl_mount().
 *
 *     CONFIG_WL_SECTOR_SIZE is set to 512 (in sdkconfig.defaults) so the USB
 *     host sees standard 512-byte logical sectors, as required by BIOS/UEFI.
 *
 * SPDX-License-Identifier: MIT
 ******************************************************************************/
#include <stddef.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_err.h"
#include "esp_log.h"
#include "esp_partition.h"
#include "wear_levelling.h"

#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tinyusb_msc.h"

/* ---------------------------------------------------------------------------
 * Configuration constants
 * ------------------------------------------------------------------------- */

/* Partition table label for the FAT data partition (matches partitions.csv). */
#define THUMBDRIVE_PARTITION_LABEL   "storage"

/* Tag used for ESP_LOG output throughout the application. */
static const char *TAG = "thumbdrive";

/* ---------------------------------------------------------------------------
 * Global state
 * ------------------------------------------------------------------------- */

/**
 * Wear-levelling handle for the flash partition backing the USB MSC storage.
 *
 * `wl_mount()` populates this opaque handle; `tinyusb_msc_new_storage_spiflash()`
 * reads sector info (count, size) through it and wires it into the internal
 * diskio layer so the USB host sees a block device backed by SPI flash.
 *
 * Note: wear-levelling metadata (position tables, config) is stored at the
 * END of the flash partition (see WL_Flash::config()).  This means virtual
 * address 0 maps to physical flash at the partition start -- data written by
 * the USB host at LBA 0 (the MBR) is stored at the physical beginning of
 * the partition and is NOT overwritten during wl_mount() initialisation.
 */
static wl_handle_t s_wl_handle = WL_INVALID_HANDLE;

/**
 * Opaque handle returned by `tinyusb_msc_new_storage_spiflash()`.
 *
 * With mount_point = TINYUSB_MSC_STORAGE_MOUNT_USB, the TinyUSB stack's
 * built-in tud_mount_cb() / tud_umount_cb() handlers handle ownership switching.
 * When a USB host connects, tud_mount_cb() -> msc_storage_mount_to_usb() ->
 * msc_storage_unmount() switches the storage to USB-host ownership.  When the
 * host disconnects, tud_umount_cb() -> msc_storage_mount_to_app() switches back.
 *
 * Since we use MOUNT_USB (not MOUNT_APP), the FAT filesystem is NEVER mounted
 * to the firmware.  The app has no file-system access; it only serves raw
 * sectors through the wear-levelling layer to the USB host.
 */
static tinyusb_msc_storage_handle_t s_msc_storage = NULL;

/* ---------------------------------------------------------------------------
 * app_main
 * ------------------------------------------------------------------------- */

void app_main(void)
{
    /* -------------------------------------------------------------------------
     * 1. Locate the FAT data partition declared in partitions.csv.
     *
     *    We search for a partition of type DATA / subtype FAT with the label
     *    "storage".  If the partition table doesn't define it, there is
     *    nothing to expose over USB -- bail out early.
     *
     *    IMPORTANT: This partition must be listed in partitions.csv and the
     *    build must use CONFIG_PARTITION_TABLE_CUSTOM=y so that the project's
     *    partitions.csv (not the default single-app table) is flashed.
     * ------------------------------------------------------------------------- */
    const esp_partition_t *partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA,
        ESP_PARTITION_SUBTYPE_DATA_FAT,
        THUMBDRIVE_PARTITION_LABEL
    );

    if (partition == NULL) {
        ESP_LOGE(TAG,
                 "FAT partition \"%s\" not found -- verify partitions.csv and "
                 "CONFIG_PARTITION_TABLE_CUSTOM=y",
                 THUMBDRIVE_PARTITION_LABEL);
        return;
    }

    /* -------------------------------------------------------------------------
     * 2. Mount wear-levelling on the raw partition sectors.
     *
     *    Wear-levelling abstracts the physical flash layout into uniform
     *    sectors, preventing early flash wear in hot-spots.  The resulting
     *    `s_wl_handle` is consumed by tinyusb_msc_new_storage_spiflash() below.
     *
     *    Key properties of the ESP-IDF WL layer (verified in WL_Flash.cpp):
     *      *   Sector size: CONFIG_WL_SECTOR_SIZE (512 here)
     *      *   Metadata (position tables, config) stored at END of partition
     *      *   Virtual address 0 = physical flash at partition start
     *      *   First mount on blank flash: erases only END sectors for metadata
     *      *   Existing data at the beginning (e.g. pre-flashed MBR) is preserved
     * ------------------------------------------------------------------------- */
    esp_err_t wl_err = wl_mount(partition, &s_wl_handle);
    if (wl_err != ESP_OK) {
        ESP_LOGE(TAG, "wl_mount failed (0x%x)", wl_err);
        return;
    }

    /* -------------------------------------------------------------------------
     * 3. Install the TinyUSB device stack.
     *
     *    TINYUSB_DEFAULT_CONFIG() produces a tinyusb_config_t with:
     *      - port: TINYUSB_PORT_FULL_SPEED_0 (ESP32-S3 default, 12 Mbps FS)
     *      - phy: internal PHY, no VBUS monitoring
     *      - task: 4096-byte stack, priority 5, core 1
     *      - descriptors: all NULL -> Kconfig defaults (MSC enabled via
     *        CONFIG_TINYUSB_MSC_ENABLED=y)
     *
     *    tinyusb_driver_install() configures the USB PHY, sets up descriptors,
     *    initialises the TinyUSB stack, and starts the background USB event
     *    task.
     * ------------------------------------------------------------------------- */
    tinyusb_config_t tusb_cfg = TINYUSB_DEFAULT_CONFIG();

    esp_err_t tusb_err = tinyusb_driver_install(&tusb_cfg);
    if (tusb_err != ESP_OK) {
        ESP_LOGE(TAG, "tinyusb_driver_install failed (0x%x)", tusb_err);
        return;
    }

    /* -------------------------------------------------------------------------
     * 4. Create the MSC storage instance backed by SPI flash.
     *
     *    tinyusb_msc_storage_config_t bundles:
     *      .medium.wl_handle -- wear-levelling handle from step 2.
     *      .fat_fs -- FAT filesystem configuration:
     *        .base_path    = NULL -> Kconfig default CONFIG_TINYUSB_MSC_MOUNT_PATH
     *                         ("/data").  NOT USED with MOUNT_USB (see below).
     *        .config       = VFS_FAT_MOUNT_DEFAULT_CONFIG() -- max_files=5,
     *                         format_if_mount_failed=false.  Not used with
     *                         MOUNT_USB.
     *        .do_not_format = false -> if FAT mount runs (MOUNT_APP), auto-format.
     *                         Irrelevant with MOUNT_USB (FAT mount never runs).
     *        .format_flags  = 0 -> FM_ANY.  Irrelevant with MOUNT_USB.
     *      .mount_point = TINYUSB_MSC_STORAGE_MOUNT_USB -- key change from
     *        MOUNT_APP.  See changelog above for why.
     *
     *    When MOUNT_USB is selected:
     *      *   msc_storage_mount() is NEVER called inside
     *        tinyusb_msc_new_storage_spiflash()
     *      *   No FAT filesystem is mounted to the firmware
     *      *   No auto-format (f_mkfs) is triggered
     *      *   tud_msc_test_unit_ready_cb() returns true immediately
     *        (storage->mount_point == MOUNT_USB)
     *      *   tud_msc_read10_cb() / tud_msc_write10_cb() serve raw sectors
     *        via wl_read() / wl_write() through the wear-levelling layer
     *
     *    This function also auto-installs the internal MSC driver (with
     *    auto_mount_off=false, i.e. USB connect/disconnect auto-remounting
     *    is active).
     * ------------------------------------------------------------------------- */
    const tinyusb_msc_storage_config_t msc_cfg = {
        .medium.wl_handle = s_wl_handle,
        .fat_fs = {
            .base_path        = NULL, /* Kconfig default, unused with MOUNT_USB */
            .config           = VFS_FAT_MOUNT_DEFAULT_CONFIG(),
            .do_not_format     = false, /* Irrelevant -- FAT mount never runs */
            .format_flags      = 0,     /* Irrelevant -- FAT mount never runs */
        },
        .mount_point = TINYUSB_MSC_STORAGE_MOUNT_USB, /* <-- key change */
    };

    esp_err_t msc_err = tinyusb_msc_new_storage_spiflash(&msc_cfg, &s_msc_storage);
    if (msc_err != ESP_OK) {
        ESP_LOGE(TAG, "tinyusb_msc_new_storage_spiflash failed (0x%x)", msc_err);
        return;
    }

    /* ---------------------------------------------------------------------
     * 5. Storage is now in raw-sector mode (MOUNT_USB).  No FAT filesystem
     *    is mounted on the firmware side.  The background TinyUSB task --
     *    started inside tinyusb_driver_install() in step 3 -- continuously
     *    services USB interrupts and calls the tud_msc_*_cb() handlers.
     *
     *    When a USB host connects, tud_mount_cb() -> msc_storage_mount_to_usb()
     *    fires.  Since mount_point is already MOUNT_USB, this is a no-op
     *    (msc_storage_unmount() returns ESP_OK immediately).
     *
     *    The USB host sees a raw block device with 512-byte sectors (because
     *    CONFIG_WL_SECTOR_SIZE=512).  Partition it, format it, and copy boot
     *    files from a Linux host.
     *
     *    All that remains is to idle forever.
     * ------------------------------------------------------------------- */
    ESP_LOGI(TAG,
             "USB MSC raw-storage initialised (512-byte sectors, no FAT mount) -- "
             "plug into a PC to partition and format");

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
