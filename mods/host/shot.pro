# qmake project for the screenshot testing extension (see shot.cpp).
TEMPLATE = lib
CONFIG += shared plugin no_plugin_name_prefix
QT += quick
TARGET = pp-shot
SOURCES += shot.cpp
