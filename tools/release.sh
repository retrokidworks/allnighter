#!/bin/sh
# 직접 배포판을 만든다: Developer ID 서명 → DMG → 공증·스테이플 → GitHub 릴리스.
# 사용: tools/release.sh <버전>   (personal/allnighter 에서, 예: tools/release.sh 0.1.0)
# 필요: 키체인의 "Developer ID Application" 신원, ASC API 키(공증), gh 로그인.
set -e
cd "$(dirname "$0")/.."

version="$1"
[ -n "$version" ] || { echo "사용: tools/release.sh <버전>" >&2; exit 1; }
repo=retrokidworks/allnighter
api_key_id=2TB4M76BXX
api_issuer=69a6de8b-dd84-47e3-e053-5b8c7c11a4d1
api_key="$HOME/.appstoreconnect/private_keys/AuthKey_$api_key_id.p8"
out=build/release
dmg="$out/Allnighter-$version.dmg"

security find-identity -v -p codesigning | rg -q '"Developer ID Application' || { echo "키체인에 Developer ID Application 신원이 없다" >&2; exit 1; }
[ -f "$api_key" ] || { echo "$api_key 가 없다" >&2; exit 1; }
[ ! -e "$dmg" ] || { echo "$dmg 가 이미 있다 — 같은 버전을 다시 내지 않는다" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"
xcodegen generate -q
# 빌드 번호는 버전에서 만든다(0.1.0 → 100). 같은 버전이면 같은 번호라 다시 내면 위에서 막힌다.
build_number=$(echo "$version" | awk -F. '{ print $1 * 10000 + $2 * 100 + $3 }')
xcodebuild -project Allnighter.xcodeproj -scheme Allnighter -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/release-derived \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build -quiet
app=build/release-derived/Build/Products/Release/Allnighter.app

# 인텔·Apple Silicon 둘 다 들어간 유니버설인지, 헬퍼까지 Developer ID·hardened runtime 으로 서명됐는지 확인한다.
built_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$built_version" = "$version" ] || { echo "앱 버전이 $built_version 이다(기대: $version)" >&2; exit 1; }
for executable in Allnighter AllnighterHelper; do
  [ "$(lipo -archs "$app/Contents/MacOS/$executable")" = "x86_64 arm64" ] || { echo "$executable 가 유니버설이 아니다" >&2; exit 1; }
done
for binary in "$app/Contents/MacOS/AllnighterHelper" "$app"; do
  codesign --verify --strict --deep "$binary"
  codesign -dvv "$binary" 2>&1 | rg -q 'Authority=Developer ID Application' || { echo "$binary 가 Developer ID 로 서명되지 않았다" >&2; exit 1; }
  codesign -dvv "$binary" 2>&1 | rg -q 'flags=.*runtime' || { echo "$binary 에 hardened runtime 이 없다" >&2; exit 1; }
  # 디버그용 get-task-allow 가 붙으면 공증이 거부된다.
  ! codesign -d --entitlements - "$binary" 2>/dev/null | rg -q get-task-allow || { echo "$binary 에 get-task-allow 가 있다" >&2; exit 1; }
done

stage="$out/dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Allnighter" -srcfolder "$stage" -format UDZO "$dmg"
codesign --sign "Developer ID Application" --timestamp "$dmg"

# notarytool 은 거부(Invalid)돼도 0 으로 끝난다 — 상태를 직접 본다.
status=$(xcrun notarytool submit "$dmg" --key "$api_key" --key-id "$api_key_id" --issuer "$api_issuer" --wait --output-format json |
  python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["status"], d["id"])')
echo "notarization: $status"
case "$status" in
  Accepted*) ;;
  *) echo "공증 실패 — xcrun notarytool log ${status#* } 로 원인을 본다" >&2; exit 1 ;;
esac
xcrun stapler staple "$dmg"
spctl -a -t open --context context:primary-signature -vv "$dmg"

sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
gh release create "v$version" "$dmg" --repo "$repo" --title "Allnighter $version" --generate-notes
# Homebrew cask 를 새 버전으로 맞춘다. 올리기는 scripts/personal-publish.sh homebrew-tap.
cask=../homebrew-tap/Casks/allnighter.rb
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
echo "released v$version sha256=$sha — $cask 갱신됨, 커밋 후 scripts/personal-publish.sh homebrew-tap"
