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

add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/boot.img
    COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_CURRENT_SOURCE_DIR}/../embedded-hidos/boot.img
        boot.img
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/../embedded-hidos/boot.img
)

add_custom_command(
    OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/boot_img.o
    COMMAND arm-none-eabi-objcopy
        -I binary
        -O elf32-littlearm
        -B arm
        --rename-section .data=.rodata,alloc,load,readonly,data,contents
        boot.img
        boot_img.o
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
    DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/boot.img
)

set_source_files_properties(
    ${CMAKE_CURRENT_BINARY_DIR}/boot_img.o
    PROPERTIES GENERATED TRUE
)

add_executable(v30_control main.cpp gpio_hidos.S usb_ports.c usb_descriptors.c)

# Embed git revision into firmware version (v command & picotool info)
execute_process(
    COMMAND git rev-parse --short HEAD
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    OUTPUT_VARIABLE GIT_REV
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if(NOT GIT_REV)
    set(GIT_REV "unknown")
else()
    execute_process(
        COMMAND git diff-index --quiet HEAD -- .
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        RESULT_VARIABLE GIT_DIRTY
        ERROR_QUIET
    )
    if(NOT GIT_DIRTY EQUAL 0)
        set(GIT_REV "${GIT_REV}-dirty")
    endif()
endif()
target_compile_definitions(v30_control PRIVATE GIT_REV="${GIT_REV}")
pico_set_program_version(v30_control "${GIT_REV}")

# Overclocking (c s <MHz>) needs a slower flash clock: sys clock / 4.
pico_define_boot_stage2(v30_boot2 ${PICO_DEFAULT_BOOT_STAGE2_FILE})
target_compile_definitions(v30_boot2 PRIVATE PICO_FLASH_SPI_CLKDIV=4)
pico_set_boot_stage2(v30_control v30_boot2)

# tusb_config.h
target_include_directories(v30_control PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_sources(v30_control PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}/disk_img.o
    ${CMAKE_CURRENT_BINARY_DIR}/boot_img.o
)


# 最適化オプション (バス制御の速度確保のため重要)
target_compile_options(v30_control PRIVATE -O3)

target_link_libraries(v30_control
    pico_stdlib
    pico_multicore  # デュアルコア用
    hardware_gpio
    hardware_clocks
    hardware_vreg
    hardware_pwm # Added for PWM functionality
    pico_unique_id
    tinyusb_device # 4ポートCDC (usb_ports.c)
)

# USBはusb_ports.cが直接TinyUSBで扱う (pico_stdio_usbは1ポートのみのため不使用)
pico_enable_stdio_usb(v30_control 0)
pico_enable_stdio_uart(v30_control 0)

pico_add_extra_outputs(v30_control)
