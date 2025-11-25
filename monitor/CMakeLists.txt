cmake_minimum_required(VERSION 3.13)
include(pico_sdk_import.cmake)

project(v30_control C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(v30_control main.cpp)

# 最適化オプション (バス制御の速度確保のため重要)
target_compile_options(v30_control PRIVATE -O3)

target_link_libraries(v30_control
    pico_stdlib
    pico_multicore  # デュアルコア用
    hardware_gpio
    hardware_clocks
)

# USBシリアル有効、UART無効
pico_enable_stdio_usb(v30_control 1)
pico_enable_stdio_uart(v30_control 0)

pico_add_extra_outputs(v30_control)
