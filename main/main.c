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
 *   Key design decision: mount_point = TINYUSB_MSC_STORAGE_MOUNT_APP at
 *   creation time.  This causes tinyusb_msc_new_storage_spiflash() to
 *   automatically mount the FAT filesystem and auto-format the partition
 *   (FM_ANY) if no valid filesystem is found.  The TinyUSB stack's built-in
 *   tud_mount_cb() / tud_umount_cb() callbacks then automatically switch the
 *   storage between APP ownership (firmware) and USB ownership (host) when
 *   the USB cable is plugged/unplugged, so no manual mount/unmount is needed
 *   in app_main().
 *
 *   Includes updated:
 *     - "tinyusb.h"            (was already included)
 *     - "tinyusb_default_config.h"  (NEW — provides TINYUSB_DEFAULT_CONFIG())
 *     - "tinyusb_msc.h"        (NEW — replaces deprecated tusb_msc_storage.h)
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
 */
static wl_handle_t s_wl_handle = WL_INVALID_HANDLE;

/**
 * Opaque handle returned by `tinyusb_msc_new_storage_spiflash()`.
 *
 * After the storage instance is created, the TinyUSB stack's built-in
 * tud_mount_cb / tud_umount_cb handlers automatically call
 * tinyusb_msc_set_storage_mount_point() on this handle to switch ownership
 * between the firmware (APP) and the USB host whenever the cable is
 * plugged or unplugged.  Storing the handle lets us (optionally) query
 * storage status later, e.g. with tinyusb_msc_get_storage_capacity().
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
     *    nothing to expose over USB — bail out early.
     * ------------------------------------------------------------------------- */
    const esp_partition_t *partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA,
        ESP_PARTITION_SUBTYPE_DATA_FAT,
        THUMBDRIVE_PARTITION_LABEL
    );

    if (partition == NULL) {
        ESP_LOGE(TAG,
                 "FAT partition \"%s\" not found — verify partitions.csv",
                 THUMBDRIVE_PARTITION_LABEL);
        return;
    }

    /* -------------------------------------------------------------------------
     * 2. Mount wear-levelling on the raw partition sectors.
     *
     *    Wear-levelling abstracts the physical flash layout into uniform
     *    sectors, preventing early flash wear in hot-spots.  The resulting
     *    `s_wl_handle` is consumed by tinyusb_msc_new_storage_spiflash() below.
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
     *      - port: TINYUSB_PORT_FULL_SPEED_0 (ESP32-S3 default)
     *      - phy: internal PHY, no VBUS monitoring
     *      - task: 4096-byte stack, priority 5, core 1
     *      - descriptors: all NULL → Kconfig defaults (MSC enabled via
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
     *      .medium.wl_handle — wear-levelling handle from step 2.
     *      .fat_fs — FAT filesystem configuration:
     *        .base_path  = NULL → Kconfig default CONFIG_TINYUSB_MSC_MOUNT_PATH
     *                        (typically "/data").
     *        .config      = VFS_FAT_MOUNT_DEFAULT_CONFIG() — max_files=5,
     *                        format_if_mount_failed=false.
     *        .do_not_format = false → allow auto-format if partition is blank.
     *        .format_flags  = 0      → FM_ANY (auto-select FAT12/16/32).
     *      .mount_point = TINYUSB_MSC_STORAGE_MOUNT_APP — initially mount the
     *        filesystem on the firmware side so it gets formatted on first
     *        boot.  The TinyUSB stack automatically hands the storage to the
     *        USB host when the host connects (tud_mount_cb → mount_to_usb)
     *        and takes it back when the host disconnects
     *        (tud_umount_cb → mount_to_app).
     *
     *    This function also auto-installs the internal MSC driver (with
     *    auto_mount_off=false, i.e. USB connect/disconnect auto-remounting
     *    is active).
     * ------------------------------------------------------------------------- */
    const tinyusb_msc_storage_config_t msc_cfg = {
        .medium.wl_handle = s_wl_handle,
        .fat_fs = {
            .base_path        = NULL, /* use CONFIG_TINYUSB_MSC_MOUNT_PATH */
            .config           = VFS_FAT_MOUNT_DEFAULT_CONFIG(),
            .do_not_format     = false,
            .format_flags      = 0, /* FM_ANY — let FatFs pick FAT12/16/32 */
        },
        .mount_point = TINYUSB_MSC_STORAGE_MOUNT_APP,
    };

    esp_err_t msc_err = tinyusb_msc_new_storage_spiflash(&msc_cfg, &s_msc_storage);
    if (msc_err != ESP_OK) {
        ESP_LOGE(TAG, "tinyusb_msc_new_storage_spiflash failed (0x%x)", msc_err);
        return;
    }

    /* ---------------------------------------------------------------------
     * 5. Storage is now mounted on the firmware side (and auto-formatted
     *    if it was blank).  The background TinyUSB task — started inside
     *    tinyusb_driver_install() in step 3 — continuously services USB
     *    interrupts.  Its tud_mount_cb() will call
     *    tinyusb_msc_set_storage_mount_point(MOUNT_USB) when a host connects,
     *    transparently switching the partition from firmware ownership to
     *    USB-host ownership.
     *
     *    All that remains is to idle forever.
     * ------------------------------------------------------------------- */
    ESP_LOGI(TAG,
             "USB MSC thumb-drive initialised — plug into a PC to read/write FAT");

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
