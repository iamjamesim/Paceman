cmake_minimum_required(VERSION 3.16)
project(omarchy_watch_simulator C)
enable_testing()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)

set(LV_BUILD_CONF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/lv_conf.h" CACHE PATH "" FORCE)
set(CONFIG_LV_BUILD_DEMOS OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_USE_THORVG_INTERNAL OFF CACHE BOOL "" FORCE)
add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../firmware/managed_components/lvgl__lvgl"
    "${CMAKE_CURRENT_BINARY_DIR}/lvgl"
)

add_executable(render-watchface
    render_watchface.c
    ../firmware/main/watch_face_layout.c
    ../firmware/main/watch_allowance_layout.c
    ../firmware/main/fonts/jetbrains_mono_14_battery.c
    ../firmware/main/fonts/jetbrains_mono_22.c
    ../firmware/main/fonts/jetbrains_mono_26_connection.c
    ../firmware/main/fonts/jetbrains_mono_27.c
    ../firmware/main/fonts/jetbrains_mono_30_battery.c
    ../firmware/main/fonts/jetbrains_mono_32_agent.c
    ../firmware/main/fonts/jetbrains_mono_42.c
    ../firmware/main/fonts/jetbrains_mono_48_icons.c
    ../firmware/main/fonts/jetbrains_mono_114.c
)
target_include_directories(render-watchface PRIVATE
    ../firmware/main
    ../firmware/main/fonts
)
target_link_libraries(render-watchface PRIVATE lvgl m)

add_executable(test-profile test_profile.c)
target_include_directories(test-profile PRIVATE ../firmware/main)
# Assertions are the tests, including in the simulator's Release build.
target_compile_options(test-profile PRIVATE -UNDEBUG)

add_executable(test-rim test_rim.c)
target_include_directories(test-rim PRIVATE ../firmware/main)
target_link_libraries(test-rim PRIVATE lvgl m)
target_compile_options(test-rim PRIVATE -UNDEBUG)

add_executable(test-sound test_sound.c)
target_include_directories(test-sound PRIVATE ../firmware/main)
target_compile_options(test-sound PRIVATE -UNDEBUG)

add_test(NAME profile COMMAND test-profile)
add_test(NAME rim COMMAND test-rim)
add_test(NAME sound COMMAND test-sound)
add_test(NAME resource-colors COMMAND render-watchface ${CMAKE_CURRENT_BINARY_DIR}/test-face.ppm)

foreach(state fresh cached expired next-day detail)
    add_test(NAME freshness-${state}
        COMMAND ${CMAKE_COMMAND} -E env WATCH_PREVIEW_FRESHNESS=${state}
        $<TARGET_FILE:render-watchface> ${CMAKE_CURRENT_BINARY_DIR}/freshness-${state}.ppm)
endforeach()
