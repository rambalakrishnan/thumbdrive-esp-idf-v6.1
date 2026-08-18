# ===========================================================================
# CHANGELOG
# ---------------------------------------------------------------------------
# [v2.x-api-migration] 2026-08-18  s.ram.balakrishnan@gmail.com
#   - Removed the redundant `idf_component_get_property(tinyusb_dir ...)`
#     + `PRIV_INCLUDE_DIRS "${tinyusb_dir}/include"` lines.
#   - Reason: esp_tinyusb v2.x registers its `include/` directory as a
#     PUBLIC include dir in its own CMakeLists.txt
#     (`idf_component_register(... INCLUDE_DIRS "include")`).  Any component
#     that declares `REQUIRES esp_tinyusb` therefore receives those include
#     paths automatically.  Manually re-adding them triggered a CMake
#     validation warning: "Private include directory belongs to component
#     espressif__esp_tinyusb but is being used by component main."
#   - The `REQUIRES esp_tinyusb` directive is sufficient to pull in both
#     the include paths and the link dependency.
# ===========================================================================
idf_component_register(SRCS "main.c"
                       INCLUDE_DIRS "."
                       REQUIRES esp_tinyusb)
