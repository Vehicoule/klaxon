cmake_minimum_required(VERSION 3.16)
project(klaxon_bench_qt LANGUAGES CXX)

# Klaxon x Qt comparison benchmark runner (roadmap Phase 4c.4).
# Qt 6 via Homebrew: cmake -B build -DCMAKE_PREFIX_PATH=/opt/homebrew

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Quick)

qt_add_executable(klaxon_bench_qt
    src/main.cpp
    src/BenchDriver.h
    src/BenchImageProvider.h
    src/StarClipItem.h
    src/VideoItem.h
)

# The scene QML files are loaded from the source tree (editable without a
# rebuild; the runner is always executed via run.sh from the repo).
target_compile_definitions(klaxon_bench_qt PRIVATE
    KLAXON_QML_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml"
)

target_link_libraries(klaxon_bench_qt PRIVATE Qt6::Quick)
