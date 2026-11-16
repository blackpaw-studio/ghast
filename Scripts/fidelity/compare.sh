#!/usr/bin/env bash
# Compares a capture with its mockup. Writes, next to the capture in build/fidelity/:
#   <screen>[-dark]-side.png     mockup | capture
#   <screen>[-dark]-overlay.png  50% blend
#
#   Scripts/fidelity/compare.sh <screen> [--dark]
#
# The mockup (2880 x 1800) is cropped to the window rect x2, as `capture.sh` recorded it in
# <screen>[-dark].rect. Review is visual at native pixels: pixel diffs are only a guide,
# because the desktop backdrop and glass sampling differ.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

parse_screen_args "$@"
need magick

NAME="$SCREEN$APPEARANCE"
CAPTURE="$OUT_DIR/$NAME.png"
RECT_FILE="$OUT_DIR/$NAME.rect"
MOCKUP="$DESIGN_DIR/$(mockup_name "$SCREEN")$APPEARANCE.png"

[ -f "$CAPTURE" ] || die "no capture at $CAPTURE; run capture.sh $* first"
[ -f "$RECT_FILE" ] || die "no rect file at $RECT_FILE; run capture.sh $* first"
[ -f "$MOCKUP" ] || die "no mockup at $MOCKUP"

IFS=, read -r X Y W H < "$RECT_FILE"
CROP="$((W * 2))x$((H * 2))+$((X * 2))+$((Y * 2))"
CROPPED="$OUT_DIR/$NAME-mockup.png"

magick "$MOCKUP" -crop "$CROP" +repage "$CROPPED"
# The capture may differ in size from the mockup crop (a window clamped by its content
# size); pad both to the larger of the two so nothing is rescaled.
read -r MW MH < <(magick identify -format '%w %h\n' "$CROPPED")
read -r CW CH < <(magick identify -format '%w %h\n' "$CAPTURE")
SIZE="$((MW > CW ? MW : CW))x$((MH > CH ? MH : CH))"

pad() { magick "$1" -background none -gravity NorthWest -extent "$2" "$3"; }
pad "$CROPPED" "$SIZE" "$OUT_DIR/$NAME-mockup-padded.png"
pad "$CAPTURE" "$SIZE" "$OUT_DIR/$NAME-capture-padded.png"

magick "$OUT_DIR/$NAME-mockup-padded.png" "$OUT_DIR/$NAME-capture-padded.png" +append "$OUT_DIR/$NAME-side.png"
magick composite -blend 50 "$OUT_DIR/$NAME-capture-padded.png" "$OUT_DIR/$NAME-mockup-padded.png" "$OUT_DIR/$NAME-overlay.png"
rm -f "$OUT_DIR/$NAME-mockup-padded.png" "$OUT_DIR/$NAME-capture-padded.png"

echo "$OUT_DIR/$NAME-side.png"
echo "$OUT_DIR/$NAME-overlay.png"
