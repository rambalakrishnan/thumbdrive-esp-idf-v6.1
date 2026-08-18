idf_component_get_property(tinyusb_dir espressif__esp_tinyusb COMPONENT_DIR)

idf_component_register(SRCS "main.c"
                       INCLUDE_DIRS "."
                       PRIV_INCLUDE_DIRS "${tinyusb_dir}/include"
                       REQUIRES esp_tinyusb)
