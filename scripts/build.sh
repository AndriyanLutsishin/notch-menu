#!/bin/zsh
# Збирання Notch Menu без Xcode.
#   scripts/build.sh test     — зібрати й запустити тести
#   scripts/build.sh app      — зібрати NotchMenu.app у build/ і підписати
#   scripts/build.sh install  — те саме + скопіювати в ~/Applications і запустити
#
# Чому не `swift build`: у цих Command Line Tools SwiftPM зламаний (dyld: Symbol not found),
# а новий SDK 27 зібраний новішим Swift, ніж компілятор. Тож компілюємо напряму swiftc
# і самі вибираємо SDK, сумісний із компілятором.
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/build"
CLT=/Library/Developer/CommandLineTools
# Інструменти беремо напряму з Command Line Tools (так не заважає, якщо Xcode встановлено без прийнятої ліцензії).
SWIFTC="$CLT/usr/bin/swiftc"
NOTARYTOOL="$CLT/usr/bin/notarytool"
STAPLER="$CLT/usr/bin/stapler"
APP_NAME="NotchMenu"
BUNDLE_ID="com.andriyan.notchmenu"
mkdir -p "$BUILD"

# --- вибір SDK, сумісного з компілятором ---------------------------------
compiler_ver=$("$SWIFTC" --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)
SDK=""
for sdk in $(ls -d $CLT/SDKs/MacOSX*.*.sdk 2>/dev/null | sort -rV); do
  iface="$sdk/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
  [[ -f "$iface" ]] || continue
  sdk_ver=$(sed -nE 's/.*swift-compiler-version: Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' "$iface" | head -1)
  if [[ "$sdk_ver" == "$compiler_ver" ]]; then SDK="$sdk"; break; fi
done
[[ -n "$SDK" ]] || { echo "Не знайшов SDK під Swift $compiler_ver"; exit 1; }
echo "• Swift $compiler_ver, SDK: ${SDK:t}"

COMMON=(-sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5)

build_core() {
  local mode=$1   # debug | release
  local opt=(-Onone -enable-testing -g)
  [[ $mode == release ]] && opt=(-O)
  mkdir -p "$BUILD/$mode"
  "$SWIFTC" "${COMMON[@]}" "${opt[@]}" -parse-as-library -module-name NotchCore \
    -emit-module -emit-module-path "$BUILD/$mode/NotchCore.swiftmodule" \
    -emit-library -static -o "$BUILD/$mode/libNotchCore.a" \
    "$ROOT"/Sources/NotchCore/*.swift
}

run_tests() {
  build_core debug
  "$SWIFTC" "${COMMON[@]}" -Onone -parse-as-library -module-name NotchCoreTests \
    -I "$BUILD/debug" -L "$BUILD/debug" -lNotchCore \
    "$ROOT"/Tests/NotchCoreTests/*.swift -o "$BUILD/debug/tests"
  "$BUILD/debug/tests"
}

build_app() {
  build_core release
  local bin="$BUILD/release/$APP_NAME"
  "$SWIFTC" "${COMMON[@]}" -O -module-name "$APP_NAME" \
    -I "$BUILD/release" -L "$BUILD/release" -lNotchCore \
    "$ROOT"/Sources/NotchMenu/*.swift -o "$bin"

  local app="$BUILD/$APP_NAME.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$bin" "$app/Contents/MacOS/$APP_NAME"
  cp "$ROOT/Resources/Info.plist" "$app/Contents/Info.plist"
  [[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$app/Contents/Resources/"
  # Підпис (за пріоритетом):
  #  1) «Developer ID Application» з облікового запису Apple — для публікації (+ перевірка Apple, див. `release`);
  #  2) власний сертифікат «Notch Menu Signing» — дозволи macOS не злітають після оновлень;
  #  3) «домашній» ad-hoc підпис.
  # Явно вибрати підпис: SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh app
  local devid="${SIGN_IDENTITY:-}"
  if [[ -z "$devid" ]]; then
    devid=$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
  fi
  if [[ -n "$devid" ]]; then
    echo "• Підпис: $devid (+ hardened runtime)"
    codesign --force --sign "$devid" --identifier "$BUNDLE_ID" --options runtime --timestamp \
      --entitlements "$ROOT/Resources/NotchMenu.entitlements" "$app"
  elif security find-certificate -c "Notch Menu Signing" >/dev/null 2>&1; then
    echo "• Підпис: власний сертифікат «Notch Menu Signing»"
    codesign --force --sign "Notch Menu Signing" --identifier "$BUNDLE_ID" "$app"
  else
    echo "• Підпис: домашній (сертифіката поки немає)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$app"
  fi
  codesign --verify --strict "$app" && echo "• Зібрано й підписано: $app"
}

install_app() {
  build_app
  local dest="$HOME/Applications"
  mkdir -p "$dest"
  pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
  rm -rf "$dest/$APP_NAME.app"
  cp -R "$BUILD/$APP_NAME.app" "$dest/"
  # Робочу копію прибираємо, щоб у системі була лише одна програма Notch Menu.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$BUILD/$APP_NAME.app" 2>/dev/null || true
  rm -rf "$BUILD/$APP_NAME.app"
  open "$dest/$APP_NAME.app"
  echo "• Встановлено й запущено: $dest/$APP_NAME.app"
}

# Реліз для людей: підпис Developer ID → перевірка Apple (нотаризація) → «скоба» → dist/NotchMenu.zip.
# Один раз перед першим релізом власник сам зберігає пароль для нотаризації (див. README):
#   "$NOTARYTOOL" store-credentials NotchMenu --apple-id <пошта> --team-id <TEAMID>
release_app() {
  build_app
  local app="$BUILD/$APP_NAME.app"
  local sig
  sig=$(codesign -dvv "$app" 2>&1 || true)
  [[ "$sig" == *"Authority=Developer ID Application"* ]] || {
    echo "✗ Немає підпису Developer ID — спершу постав сертифікат «Developer ID Application»."; exit 1; }
  mkdir -p "$ROOT/dist"
  local zip="$ROOT/dist/NotchMenu.zip"
  rm -f "$zip"
  ditto -c -k --norsrc --keepParent "$app" "$zip"
  echo "• Відправляю на перевірку Apple (зазвичай 1–5 хв)…"
  local out
  out=$("$NOTARYTOOL" submit "$zip" --keychain-profile NotchMenu --wait 2>&1) || true
  echo "$out" | sed 's/^/  /'
  if ! echo "$out" | grep -q "status: Accepted"; then
    local id
    id=$(echo "$out" | sed -nE 's/^ *id: ([0-9a-f-]+).*/\1/p' | head -1)
    echo "✗ Apple не прийняла програму. Причина:"
    [[ -n "$id" ]] && "$NOTARYTOOL" log "$id" --keychain-profile NotchMenu
    exit 1
  fi
  "$STAPLER" staple "$app"
  rm -f "$zip"
  ditto -c -k --norsrc --keepParent "$app" "$zip"
  if spctl --assess --type execute -vv "$app" 2>&1 | sed 's/^/• Gatekeeper: /'; then
    echo "• Готово до публікації: $zip"
  else
    echo "✗ Gatekeeper відмовив — програму не можна публікувати"; exit 1
  fi
}

case "${1:-app}" in
  test) run_tests ;;
  app) build_app ;;
  install) install_app ;;
  release) release_app ;;
  *) echo "Використання: $0 test|app|install|release"; exit 1 ;;
esac
