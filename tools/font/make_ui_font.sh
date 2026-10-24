#!/bin/bash
# Writes code/gamefontui.pas, the UI font (a texture font embedded in the
# program, so it needs no FreeType and works in the browser and on Android):
# DejaVu Sans at 20 like CGE's default UI font, with the glyphs of
# tools/font/ui_font_chars.txt (CGE's common characters, Latin-1, Latin
# Extended-A, Romanian's comma-below S and T, a few quotes and dashes).
#
#   tools/font/make_ui_font.sh <castle-engine directory>
#
# needs texture-font-to-pascal built in <castle-engine>/tools/texture-font-to-pascal
set -eu
CGE=${1:?castle-engine directory}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
cd "$ROOT/code"
"$CGE/tools/texture-font-to-pascal/texture-font-to-pascal" --size 20 \
  "$CGE/src/fonts/data/DejaVuSans.ttf" \
  --sample-text-file="$HERE/ui_font_chars.txt" \
  --unit-name GameFontUi --function-name Font_GameUi
echo "Wrote $ROOT/code/gamefontui.pas"
