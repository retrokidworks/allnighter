#!/bin/sh
# App Store 스크린샷을 store/screenshots.html 에서 2880×1800 JPEG 로 찍는다.
set -e
cd "$(dirname "$0")"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for shot in 1 2; do
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --window-size=1440,900 --force-device-scale-factor=2 \
    --virtual-time-budget=4000 --screenshot="$PWD/shot-$shot.png" "file://$PWD/screenshots.html?shot=$shot" 2>/dev/null
  sips -s format jpeg -s formatOptions 92 "shot-$shot.png" --out "0$shot.jpg" >/dev/null
  rm "shot-$shot.png"
done
sips -g pixelWidth -g pixelHeight 01.jpg 02.jpg | rg pixel
