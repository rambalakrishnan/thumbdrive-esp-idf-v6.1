#include <stddef.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_partition.h"
#include "wear_levelling.h"
#include "tinyusb.h"
#include "tusb_msc_storage.h"

static wl_handle_t s_wl_handle = WL_INVALID_HANDLE;

void app_main(void) 
{
    // Find the giant storage block mapped out in partitions.csv
    const esp_partition_t *partition = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, 
        ESP_PARTITION_SUBTYPE_DATA_FAT, 
        "storage"
    );

    if (partition == NULL) {
        return; 
    }

    // Mount wear leveling onto the raw partition sectors
    if (wl_mount(partition, &s_wl_handle) != ESP_OK) {
        return;
    }

    // Modern zero-initialized hardware config tells driver 
    // to fall back onto structural defaults from menuconfig
    tinyusb_config_t tusb_cfg = { 0 };

    // Install the low-level hardware device stack paths
    if (tinyusb_driver_install(&tusb_cfg) != ESP_OK) {
        return;
    }

    // Modern configuration structure layout nesting the wear-leveling handle
    tinyusb_msc_slots_config_t msc_cfg;
    memset(&msc_cfg, 0, sizeof(msc_cfg));
    
    msc_cfg.wl_handle = s_wl_handle;
    msc_cfg.callback_mount_changed = NULL;

    // Run the streamlined MSC initialization driver
    if (tusb_msc_storage_init(&msc_cfg) != ESP_OK) {
        return;
    }

    // The background TinyUSB interrupt threads handle all computer data transfers.
    // The main processing core can safely go to sleep forever.
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}
