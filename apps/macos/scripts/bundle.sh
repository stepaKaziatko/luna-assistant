#!/bin/sh
# Собирает build/Luna.app из Xcode-проекта: xcodegen → xcodebuild → подпись.
# Запускать приложение нужно бандлом (open build/Luna.app): только так macOS выдаёт права
# Automation, микрофона и Accessibility самой Luna, а не терминалу, из которого её запустили.
#
#   scripts/bundle.sh            # release: universal (arm64 + x86_64), переносится на другую машину
#   scripts/bundle.sh debug      # быстрая сборка под свою архитектуру
#
# LUNA_SIGN_IDENTITY — сертификат для подписи. По умолчанию подпись ad-hoc: она меняется с каждой
# сборкой, и macOS может попросить выдать права заново. С постоянным сертификатом права сохраняются.
# LUNA_BUILD_NUMBER — номер сборки (CFBundleVersion); в CI это номер прогона.
#
# Нужны Xcode 26+ (код рассчитан на Swift 6.2) и xcodegen (brew install xcodegen).
set -eu

config="${1:-release}"
macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="$macos_dir/build/Luna.app"

fail() { printf '✗ %s\n' "$*" >&2; exit 1; }
command -v xcodegen >/dev/null || fail "нужен xcodegen: brew install xcodegen"

case "$config" in
  release) configuration=Release; archs='ARCHS=arm64 x86_64' ;;
  debug) configuration=Debug; archs='ONLY_ACTIVE_ARCH=YES' ;;
  *) fail "неизвестная конфигурация: $config (release | debug)" ;;
esac

cd "$macos_dir"
xcodegen generate --quiet
# Подпись — ниже, своим сертификатом или ad-hoc: в проекте нет команды Apple Developer.
xcodebuild -quiet -project Luna.xcodeproj -scheme Luna -configuration "$configuration" \
  -destination 'generic/platform=macOS' -derivedDataPath .build/xcode \
  "$archs" ONLY_ACTIVE_ARCH="$([ "$config" = release ] && echo NO || echo YES)" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

rm -rf "$app"
mkdir -p "$macos_dir/build"
cp -R ".build/xcode/Build/Products/$configuration/Luna.app" "$app"
if [ -n "${LUNA_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LUNA_BUILD_NUMBER" "$app/Contents/Info.plist"
fi

# Энтайтлменты (микрофон, контакты, Apple Events) нужны в подписи: без них hardened runtime
# не даст macOS спросить разрешение.
codesign --force --options runtime --entitlements "$macos_dir/Resources/Luna.entitlements" \
  --sign "${LUNA_SIGN_IDENTITY:--}" "$app"
echo "Готово: $app"
