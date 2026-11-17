#!/bin/sh
# Cross/native build of NGB_Render.dll.
#   MSVC:   open a x64 Native Tools prompt and run build-msvc.bat
#   zig:    ./build.sh          (zig cc, no Visual Studio needed)
set -e
ZIG=${ZIG:-zig}
OUT=${1:-NGB_Render.dll}
"$ZIG" cc -target x86_64-windows-gnu -O2 -shared -fms-extensions \
    -DNGD_BUILD=1 -DNGB_RENDER_EXPORTS \
    -o "$OUT" \
    src/ngb_render.c src/ngb_gfx.c src/ngb_card.c src/ngb_json.c \
    minhook/src/hook.c minhook/src/buffer.c minhook/src/trampoline.c \
    minhook/src/hde/hde64.c \
    -I minhook/include -I src \
    -ld3d11 -ldxgi -lgdi32 -luser32 -lole32 -loleaut32
echo "built $OUT"
