#!/bin/sh
# Mac App Store 판(AllnighterAppStore 타깃)을 아카이브해 pkg 로 만들고 App Store Connect 에 올린다.
# 사용: tools/app-store.sh <버전> [--no-upload]   (personal/allnighter 에서, 예: tools/app-store.sh 0.1.1)
# 서명 신원은 이름이 아니라 SHA1 로 고정한다 — 키체인에 폐기된 옛 "Apple Distribution" 이 같은 이름으로 남아 있다.
# 프로필은 2026-09-27 ASC API 로 발급했다(Allnighter Mac App Store, 5XQ7FT43AP).
set -e
cd "$(dirname "$0")/.."

version="$1"
[ -n "$version" ] || { echo "사용: tools/app-store.sh <버전> [--no-upload]" >&2; exit 1; }
team_id=6P57Y84B45
bundle_id=com.retrokidworks.allnighter
app_sign_sha1=29740F53BEA5338630752157149249EF4527E06A       # Apple Distribution
installer_sign_sha1=7C4B4AE527B501F34203F055417D4FD5D375E2AB # 3rd Party Mac Developer Installer
profile_uuid=7c8f41a6-3677-4f9a-8f86-9f0e6e70673f
api_key_id=2TB4M76BXX
api_issuer=69a6de8b-dd84-47e3-e053-5b8c7c11a4d1

# 빌드 번호는 시각으로 찍는다 — 올릴 때마다 커지기만 하면 된다.
build_number=$(date +%y%m%d%H%M)
out=build/app-store
archive="$out/Allnighter.xcarchive"
rm -rf "$out"
mkdir -p "$out"
xcodegen generate -q

xcodebuild -project Allnighter.xcodeproj -scheme AllnighterAppStore -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$app_sign_sha1" DEVELOPMENT_TEAM="$team_id" \
  PROVISIONING_PROFILE_SPECIFIER="$profile_uuid" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  archive -quiet

app="$archive/Products/Applications/Allnighter.app"
[ "$(lipo -archs "$app/Contents/MacOS/Allnighter")" = "x86_64 arm64" ] || { echo "유니버설이 아니다" >&2; exit 1; }
# 심사는 바이너리의 비공개 API 흔적을 본다 — 직접 배포판 전용 코드가 섞였으면 여기서 멈춘다.
! strings "$app/Contents/MacOS/Allnighter" | rg -q 'DisplayServices|SleepDisabled|IOPMSetSystemPowerSetting' || { echo "App Store 판에 비공개 API 흔적이 있다" >&2; exit 1; }
[ ! -e "$app/Contents/Library/LaunchDaemons" ] || { echo "App Store 판에 헬퍼가 들어갔다" >&2; exit 1; }

cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$team_id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$app_sign_sha1</string>
  <key>installerSigningCertificate</key><string>$installer_sign_sha1</string>
  <key>provisioningProfiles</key>
  <dict><key>$bundle_id</key><string>$profile_uuid</string></dict>
</dict>
</plist>
PLIST

# Homebrew rsync 가 PATH 앞에 있으면 export 가 "Copy failed" 로 죽는다.
PATH="/usr/bin:$PATH" xcodebuild -exportArchive -archivePath "$archive" \
  -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out" -quiet
pkg="$out/Allnighter.pkg"
echo "pkg $pkg (version $version, build $build_number)"

[ "$2" = "--no-upload" ] && exit 0
xcrun altool --upload-app -t macos -f "$pkg" --apiKey "$api_key_id" --apiIssuer "$api_issuer"
echo "업로드 완료 — App Store Connect 처리에 10~15분 걸린다. 그동안 builds 는 0건이 정상이다."
