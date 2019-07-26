#!/bin/sh

# Copyright 2018 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

. $(dirname "$0")/utils/common.shi

shell_import utils/aosp_dir.shi
shell_import utils/option_parser.shi

PROGRAM_DESCRIPTION=\
"Generates the QEMU2 sources

You usually want to run this script after you have merged in new changes from the qemu
branch.

During the QEMU configure phase a set of sources are created. These range from:

- Tracers
- Keymaps
- Stubs
"

QEMU2_TRACE=nop
option_register_var "--trace=<tracers>" QEMU2_TRACE "Tracers to enable [$QEMU2_TRACE]"

aosp_dir_register_option
option_parse "$@"
aosp_dir_parse_option



QEMU2_TOP_DIR=${AOSP_DIR}/external/qemu
QEMU2_AUTOGENERATED_DIR=${QEMU2_TOP_DIR}/qemu2-auto-generated

make_if_not_exists "$QEMU2_AUTOGENERATED_DIR"

if [ "$OPTION_TRACE" = "yes" ] ; then
  log "Enabling tracing"
  QEMU2_TRACE=simple,log
  echo "QEMU2_TRACE := yes" > $QEMU2_AUTOGENERATED_DIR/trace-config
else
  QEMU2_TRACE=nop
  echo "QEMU2_TRACE :=" > $QEMU2_AUTOGENERATED_DIR/trace-config
fi


replace_with_if_different () {
    cmp -s "$1" "$2" || mv "$2" "$1"
}


## Generate the codeamp files.
KEYCODEMAP_FILES="\
		 ui/input-keymap-atset1-to-qcode.c \
		 ui/input-keymap-linux-to-qcode.c \
		 ui/input-keymap-qcode-to-atset1.c \
		 ui/input-keymap-qcode-to-atset2.c \
		 ui/input-keymap-qcode-to-atset3.c \
		 ui/input-keymap-qcode-to-linux.c \
		 ui/input-keymap-qcode-to-qnum.c \
		 ui/input-keymap-qcode-to-sun.c \
		 ui/input-keymap-qnum-to-qcode.c \
		 ui/input-keymap-usb-to-qcode.c \
		 ui/input-keymap-win32-to-qcode.c \
		 ui/input-keymap-x11-to-qcode.c \
		 ui/input-keymap-xorgevdev-to-qcode.c \
		 ui/input-keymap-xorgkbd-to-qcode.c \
		 ui/input-keymap-xorgxquartz-to-qcode.c \
		 ui/input-keymap-xorgxwin-to-qcode.c \
"

KEYCODEMAP_GEN=$QEMU2_TOP_DIR/ui/keycodemapdb/tools/keymap-gen
KEYCODEMAP_CSV=$QEMU2_TOP_DIR/ui/keycodemapdb/data/keymaps.csv

for KEYMAP in $KEYCODEMAP_FILES; do
  dest=$(dirname "${QEMU2_AUTOGENERATED_DIR}/${KEYMAP}")
  make_if_not_exists $dest
  src=$(echo $KEYMAP | sed -E -e "s,^ui/input-keymap-(.+)-to-(.+)\.c$,\1,")
  dst=$(echo $KEYMAP | sed -E -e "s,^ui/input-keymap-(.+)-to-(.+)\.c$,\2,")
  log "GEN KEYAMP ${src} -> ${dst}"
  python ${KEYCODEMAP_GEN} \
    --lang glib2 \
    --varname qemu_input_map_${src}_to_${dst} \
    code-map ${KEYCODEMAP_CSV} ${src} ${dst} > ${QEMU2_AUTOGENERATED_DIR}/${KEYMAP}
done

make_if_not_exists $QEMU2_AUTOGENERATED_DIR/qapi
make_if_not_exists $QEMU2_AUTOGENERATED_DIR/tests
run python -B $QEMU2_TOP_DIR/scripts/qapi-gen.py \
    -o $QEMU2_AUTOGENERATED_DIR/qapi \
    -b $QEMU2_TOP_DIR/qapi/qapi-schema.json || panic "Failed to generate types from qapi-schema.json"
run python -B $QEMU2_TOP_DIR/scripts/qapi-gen.py \
    -o $QEMU2_AUTOGENERATED_DIR/tests \
    -p "test-" \
    -b $QEMU2_TOP_DIR/tests/qapi-schema/qapi-schema-test.json || panic "Failed to generate types from qapi-schema.json"
run python $QEMU2_TOP_DIR/scripts/modules/module_block.py \
     $QEMU2_AUTOGENERATED_DIR/module_block.h || panic "Failed to generate module.h"


generate_trace() {
  local OUT=$1
  local GROUP=$2
  local FORMAT=$3
  local TRACEFILE=$4
  log "GEN $OUT"
  make_if_not_exists $(dirname $QEMU2_AUTOGENERATED_DIR/$OUT)
  python $QEMU2_TOP_DIR/scripts/tracetool.py \
    --group=$GROUP --format=$FORMAT --backends=$QEMU2_TRACE $TRACEFILE > $QEMU2_AUTOGENERATED_DIR/$OUT || panic "Failed to generate trace $OUT from $TRACEFILE"
}

append_trace() {
  local OUT=trace.h
  local GROUP=$2
  local FORMAT=$3
  local TRACEFILE=$4
  log "GEN $OUT"
  make_if_not_exists $(dirname $QEMU2_AUTOGENERATED_DIR/$OUT)
  python $QEMU2_TOP_DIR/scripts/tracetool.py \
    --group=$GROUP --format=$FORMAT --backends=$QEMU2_TRACE $TRACEFILE >> $QEMU2_AUTOGENERATED_DIR/$OUT
}


LINES=$(find . -type f -iname 'trace-events')
for LINE in $LINES; do
    TRACE=$(echo ${LINE} | sed 's/\.\///')
    DIR=$(dirname $TRACE)
    NAME=$(echo ${DIR} | sed 's/\//_/g' | sed 's/-/_/g')
    if [ "${NAME}" = "." ]; then
        # Special case root
        generate_trace trace-root.c root c trace-events
        generate_trace trace-root.h root h trace-events
        generate_trace trace/generated-helpers-wrappers.h root tcg-helper-wrapper-h trace-events
        generate_trace trace/generated-helpers.c root tcg-helper-c trace-events
        generate_trace trace/generated-helpers.h root tcg-helper-h trace-events
        generate_trace trace/generated-tcg-tracers.h root tcg-h trace-events
    else
        generate_trace $DIR/trace.h $NAME h $TRACE
        generate_trace $DIR/trace.c $NAME c $TRACE
    fi
done

SUPPORTED_CPUS="i386 aarch64 arm mips"
for CPU in $SUPPORTED_CPUS; do
  generate_trace target/$CPU/generated-helpers.c root tcg-helper-c trace-events
  generate_trace target/$CPU/generated-helpers.h root tcg-helper-h trace-events
done

bash $QEMU2_TOP_DIR/scripts/hxtool -h \
    < $QEMU2_TOP_DIR/qemu-options.hx \
    > $QEMU2_AUTOGENERATED_DIR/qemu-options.def

replace_with_if_different \
    "$QEMU2_TOP_DIR/qemu-options.def" \
    $QEMU2_AUTOGENERATED_DIR/qemu-options.def


bash $QEMU2_TOP_DIR/scripts/hxtool -h \
    < $QEMU2_TOP_DIR/hmp-commands.hx \
    > $QEMU2_AUTOGENERATED_DIR/hmp-commands.h

bash $QEMU2_TOP_DIR/scripts/hxtool -h \
    < $QEMU2_TOP_DIR/hmp-commands-info.hx \
    > $QEMU2_AUTOGENERATED_DIR/hmp-commands-info.h

bash $QEMU2_TOP_DIR/scripts/hxtool -h \
    < $QEMU2_TOP_DIR/qemu-img-cmds.hx \
    > $QEMU2_AUTOGENERATED_DIR/qemu-img-cmds.h

run rm -f $QEMU2_AUTOGENERATED_DIR/gdbstub-xml-arm64.c
run bash $QEMU2_TOP_DIR/scripts/feature_to_c.sh \
    $QEMU2_AUTOGENERATED_DIR/gdbstub-xml-arm64.c \
    $QEMU2_TOP_DIR/gdb-xml/aarch64-core.xml \
    $QEMU2_TOP_DIR/gdb-xml/aarch64-fpu.xml \
    $QEMU2_TOP_DIR/gdb-xml/arm-core.xml \
    $QEMU2_TOP_DIR/gdb-xml/arm-vfp.xml \
    $QEMU2_TOP_DIR/gdb-xml/arm-vfp3.xml \
    $QEMU2_TOP_DIR/gdb-xml/arm-neon.xml

run rm -f $QEMU2_AUTOGENERATED_DIR/gdbstub-xml-arm.c
run bash $QEMU2_TOP_DIR/scripts/feature_to_c.sh \
    $QEMU2_AUTOGENERATED_DIR/gdbstub-xml-arm.c \
    $QEMU2_TOP_DIR/gdb-xml/arm-core.xml \
    $QEMU2_TOP_DIR/gdb-xml/arm-vfp.xml \
    $QEMU2_TOP_DIR/gdb-xml/arm-vfp3.xml \
    $QEMU2_TOP_DIR/gdb-xml/arm-neon.xml


# Work-around for a QEMU2 bug:
# $QEMU2/linux-headers/linux/kvm.h includes <asm/kvm.h>
# but $QEMU2/linux-headers/asm/ doesn't exist. It is supposed
# to be a symlink to $QEMU2/linux-headers/asm-x86/
#
# The end result is that the <asm/kvm.h> from the host system
# or toolchain sysroot is being included, which ends up in a
# conflict. Work around it by creating a symlink here
[ -d $QEMU2_AUTOGENERATED_DIR/asm ] &&  run unlink $QEMU2_AUTOGENERATED_DIR/asm
run ln -sf ../linux-headers/asm-x86 $QEMU2_AUTOGENERATED_DIR/asm

README="This directory is auto-generated, DO NOT EDIT!

You can recreate it by executing:

$0 $@"

echo $README > $QEMU2_AUTOGENERATED_DIR/README
