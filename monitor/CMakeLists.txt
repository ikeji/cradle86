cmake_minimum_required(VERSION 3.13)
include(${PICO_SDK_PATH}/pico_sdk_init.cmake)

project(v30_control C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/disk.img
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_CURRENT_SOURCE_DIR}/../embedded-hidos/disk.img
        disk.img
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/../embedded-hidos/disk.img
)

add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/disk_img.o
    COMMAND arm-none-eabi-objcopy
        -I binary
        -O elf32-littlearm
        -B arm
        --rename-section .data=.rodata,alloc,load,readonly,data,contents
        disk.img
        disk_img.o
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/disk.img
)

set_source_files_properties(
    ${CMAKE_CURRENT_BINARY_DIR}/disk_img.o
    PROPERTIES GENERATED TRUE
)

add_executable(v30_control main.cpp)

target_sources(v30_control PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}/disk_img.o
)


# 最適化オプション (バス制御の速度確保のため重要)
target_compile_options(v30_control PRIVATE -O3)

target_link_libraries(v30_control
    pico_stdlib
    pico_multicore  # デュアルコア用
    hardware_gpio
    hardware_clocks
    hardware_pwm # Added for PWM functionality
)

# USBシリアル有効、UART無効
pico_enable_stdio_usb(v30_control 1)
pico_enable_stdio_uart(v30_control 0)

pico_add_extra_outputs(v30_control)
