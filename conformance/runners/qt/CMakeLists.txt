cmake_minimum_required(VERSION 3.21)

project(klaxon-qt-conformance CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC OFF) # no Q_OBJECT: widgets dispatch through KxNode virtuals

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)

add_executable(klaxon-qt-conformance
    src/main.cpp
    src/kx.cpp
    src/widgets.cpp
)

target_link_libraries(klaxon-qt-conformance
    PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets
)

target_compile_options(klaxon-qt-conformance PRIVATE
    -Wall -Wextra -Wno-unused-parameter
)
