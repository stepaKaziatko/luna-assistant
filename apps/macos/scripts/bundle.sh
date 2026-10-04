#!/bin/sh
# Собирает build/Luna.app: бинарник shell, ядро (core/dist) и Info.plist.
# Запускать приложение нужно бандлом (open build/Luna.app): только так macOS выдаёт права
# Automation и Accessibility самой Luna, а не терминалу, из которого её запустили.
#
#   scripts/bundle.sh            # release: universal (arm64 + x86_64), переносится на другую машину
#   scripts/bundle.sh debug      # быстрая сборка под свою архитектуру, с debug-командами (scripts/debug-command.sh)
#
# LUNA_SIGN_IDENTITY — сертификат для подписи. По умолчанию подпись ad-hoc: она меняется с каждой
# сборкой, и macOS может попросить выдать права заново. С постоянным сертификатом права сохраняются.
# LUNA_BUILD_NUMBER — номер сборки (CFBundleVersion); в CI это номер прогона.
set -eu

config="${1:-release}"
macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$macos_dir/../.." && pwd)"
app="$macos_dir/build/Luna.app"

(cd "$repo_dir" && npm run build --silent)

case "$config" in
  release)
    # Релиз собирает xcodebuild: `swift build` с двумя --arch падает на этом пакете, а его
    # загрузчик ресурсов ищет бандлы зависимостей по абсолютному пути сборки. У xcodebuild
    # загрузчик смотрит в Contents/Resources, и приложение работает на любой машине.
    # Покрытие кода выключаем явно: схема пакета включает его и в Release, и приложение
    # при выходе писало бы default.profraw.
    (cd "$macos_dir" && xcodebuild -quiet -scheme Luna -configuration Release \
      -destination 'generic/platform=macOS' -derivedDataPath .build/xcode \
      ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
      CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO build)
    bin_dir="$macos_dir/.build/xcode/Build/Products/Release"
    ;;
  debug)
    (cd "$macos_dir" && swift build -c debug)
    bin_dir="$(cd "$macos_dir" && swift build -c debug --show-bin-path)"
    ;;
  *)
    echo "неизвестная конфигурация: $config (release | debug)" >&2
    exit 1
    ;;
esac

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/core"
cp "$macos_dir/Bundle/Info.plist" "$app/Contents/Info.plist"
if [ -n "${LUNA_BUILD_NUMBER:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LUNA_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
cp "$bin_dir/Luna" "$app/Contents/MacOS/Luna"
if [ "$config" = release ]; then
  # Ресурсные бандлы зависимостей (локализация KeyboardShortcuts). Debug-сборка находит их
  # по абсолютному пути в .build, и в .app их класть некуда: в корне бандла они ломают подпись.
  for bundle in "$bin_dir"/*.bundle; do
    if [ -e "$bundle" ]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
  done
fi

# У ядра нет runtime-зависимостей: достаточно скомпилированных файлов и пометки, что это ES-модули.
(cd "$repo_dir/core/dist" && find . -name '*.js' | cpio -pdm --quiet "$app/Contents/Resources/core")
printf '{ "type": "module" }\n' > "$app/Contents/Resources/core/package.json"

codesign --force --sign "${LUNA_SIGN_IDENTITY:--}" "$app"
echo "Готово: $app"
