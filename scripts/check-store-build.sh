#!/usr/bin/env bash
# Check a built app for the settings a store upload needs. Prints one line
# per check (PASS, FAIL or SKIP, the check name and a short reason) and exits
# non-zero if any check fails.
#
#   scripts/check-store-build.sh ios <path to .app>
#   scripts/check-store-build.sh android <path to .apk or .aab>
#
# Android checks use the latest build tools under
# ${ANDROID_SDK_ROOT:-~/Library/Android/sdk}/build-tools/ and Java from
# ${JAVA_HOME:-Android Studio's bundled JBR}. AAB manifest checks use
# bundletool when it is on PATH.
set -euo pipefail

usage() {
  echo "usage: $0 ios <path to .app> | android <path to .apk or .aab>" >&2
  exit 2
}

[ $# -eq 2 ] || usage
platform="$1"
package="$2"
[ -e "$package" ] || { echo "not found: $package" >&2; exit 2; }

failures=0

pass() { printf 'PASS  %-26s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-26s %s\n' "$1" "$2"; failures=$((failures + 1)); }
skip() { printf 'SKIP  %-26s %s\n' "$1" "$2"; }

# Strings that only the measurement harness contains. Swift keeps strings of
# 15 bytes or fewer inside the machine code, so `appkit.scenario` never shows
# in `strings` output of an iOS binary; `APPKIT_RESULT` is longer and does.
harness_markers='appkit\.scenario|APPKIT_RESULT'

# Count lines of stdin that contain a harness marker; prints 0 for none.
count_harness() { grep -cE -- "$harness_markers" || true; }

check_ios() {
  local app="$1"
  local plist="$app/Info.plist"
  [ -f "$plist" ] || { echo "no Info.plist in $app" >&2; exit 2; }

  if [ ! -f "$app/Assets.car" ]; then
    fail "App icon compiled" "Assets.car is missing"
  elif ! plutil -extract CFBundleIcons raw "$plist" >/dev/null 2>&1; then
    fail "App icon compiled" "CFBundleIcons is missing from Info.plist"
  else
    pass "App icon compiled" "Assets.car and CFBundleIcons present"
  fi

  if [ -f "$app/PrivacyInfo.xcprivacy" ]; then
    pass "Privacy manifest present" "PrivacyInfo.xcprivacy found"
  else
    fail "Privacy manifest present" "PrivacyInfo.xcprivacy is missing"
  fi

  local encryption
  if encryption="$(plutil -extract ITSAppUsesNonExemptEncryption raw "$plist" 2>/dev/null)"; then
    pass "Encryption key set" "ITSAppUsesNonExemptEncryption = $encryption"
  else
    fail "Encryption key set" "ITSAppUsesNonExemptEncryption is missing"
  fi

  if plutil -extract UIFileSharingEnabled raw "$plist" >/dev/null 2>&1; then
    fail "No file sharing" "UIFileSharingEnabled is set"
  else
    pass "No file sharing" "UIFileSharingEnabled is absent"
  fi

  local family
  family="$(plutil -extract UIDeviceFamily json -o - "$plist" 2>/dev/null | tr -d ' \n' || true)"
  if [ "$family" = "[1]" ]; then
    pass "iPhone only" "UIDeviceFamily = [1]"
  else
    fail "iPhone only" "UIDeviceFamily = ${family:-missing}"
  fi

  local exe binaries hits
  exe="$(plutil -extract CFBundleExecutable raw "$plist" 2>/dev/null || true)"
  if [ -z "$exe" ] || [ ! -f "$app/$exe" ]; then
    fail "No harness" "main executable ${exe:-(CFBundleExecutable missing)} not found"
    return
  fi
  # Debug builds keep the app code in <name>.debug.dylib next to the stub.
  binaries=("$app/$exe")
  [ -f "$app/$exe.debug.dylib" ] && binaries+=("$app/$exe.debug.dylib")
  hits="$(strings "${binaries[@]}" | count_harness)"
  if [ "$hits" -eq 0 ]; then
    pass "No harness" "no appkit.scenario or APPKIT_RESULT in $exe"
  else
    fail "No harness" "$hits harness strings (appkit.scenario, APPKIT_RESULT) in $exe"
  fi
}

find_build_tools() {
  local sdk="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
  local latest
  latest="$(ls "$sdk/build-tools" 2>/dev/null | sort -V | tail -n 1 || true)"
  [ -n "$latest" ] || { echo "no build tools under $sdk/build-tools" >&2; exit 2; }
  echo "$sdk/build-tools/$latest"
}

# Prints the certificate owner line(s) of a signed APK or AAB.
cert_owner() {
  case "$1" in
    *.apk) "$tools/apksigner" verify --print-certs "$1" 2>/dev/null | grep 'certificate DN:' || true ;;
    *.aab) keytool -printcert -jarfile "$1" 2>/dev/null | grep '^Owner:' || true ;;
  esac
}

check_signing() {
  local owner
  owner="$(cert_owner "$1")"
  if [ -z "$owner" ]; then
    fail "Not debug-signed" "no signing certificate found"
  elif printf '%s\n' "$owner" | grep -q 'CN=Android Debug'; then
    fail "Not debug-signed" "signed with the Android Debug certificate"
  else
    pass "Not debug-signed" "$(printf '%s\n' "$owner" | head -n 1 | sed -E 's/^(Signer #1 certificate DN|Owner): //')"
  fi
}

check_dex() {
  local file="$1" pattern="$2" hits
  if ! unzip -l "$file" "$pattern" >/dev/null 2>&1; then
    fail "No harness" "no $pattern in the package"
    return
  fi
  hits="$(unzip -p "$file" "$pattern" 2>/dev/null | strings | count_harness)"
  if [ "$hits" -eq 0 ]; then
    pass "No harness" "no appkit.scenario or APPKIT_RESULT in $pattern"
  else
    fail "No harness" "$hits harness strings (appkit.scenario, APPKIT_RESULT) in $pattern"
  fi
}

check_apk() {
  local apk="$1"

  if "$tools/aapt2" dump badging "$apk" 2>/dev/null | grep -q '^application-icon'; then
    pass "Launcher icon" "application-icon present"
  else
    fail "Launcher icon" "no application-icon in aapt2 dump badging"
  fi

  local manifest
  if ! manifest="$("$tools/aapt2" dump xmltree --file AndroidManifest.xml "$apk" 2>/dev/null)"; then
    fail "Not profileable" "aapt2 could not read AndroidManifest.xml"
  elif printf '%s\n' "$manifest" | grep -q 'profileable'; then
    fail "Not profileable" "manifest has a profileable element"
  else
    pass "Not profileable" "no profileable in manifest"
  fi

  check_signing "$apk"

  if "$tools/zipalign" -c -P 16 -v 4 "$apk" >/dev/null 2>&1; then
    pass "16 KB aligned" "zipalign -c -P 16 passed"
  else
    fail "16 KB aligned" "zipalign -c -P 16 failed"
  fi

  check_dex "$apk" 'classes*.dex'
}

check_aab() {
  local aab="$1"

  if command -v bundletool >/dev/null 2>&1; then
    local manifest
    manifest="$(bundletool dump manifest --bundle "$aab" 2>/dev/null || true)"
    if printf '%s\n' "$manifest" | grep -q 'android:icon='; then
      pass "Launcher icon" "android:icon set (bundletool)"
    else
      fail "Launcher icon" "no android:icon in manifest (bundletool)"
    fi
    if [ -z "$manifest" ]; then
      fail "Not profileable" "bundletool could not read the manifest"
    elif printf '%s\n' "$manifest" | grep -q 'profileable'; then
      fail "Not profileable" "manifest has a profileable element (bundletool)"
    else
      pass "Not profileable" "no profileable in manifest (bundletool)"
    fi
  else
    # Without bundletool, read the strings of the proto manifest.
    local words
    words="$(unzip -p "$aab" base/manifest/AndroidManifest.xml 2>/dev/null | strings || true)"
    if printf '%s\n' "$words" | grep -qE '(^|[^A-Za-z])icon([^A-Za-z]|$)'; then
      pass "Launcher icon" "icon attribute in proto manifest (strings, no bundletool)"
    else
      fail "Launcher icon" "no icon attribute in proto manifest (strings, no bundletool)"
    fi
    if [ -z "$words" ]; then
      fail "Not profileable" "base/manifest/AndroidManifest.xml not found"
    elif printf '%s\n' "$words" | grep -q 'profileable'; then
      fail "Not profileable" "profileable in proto manifest (strings, no bundletool)"
    else
      pass "Not profileable" "no profileable in proto manifest (strings, no bundletool)"
    fi
  fi

  check_signing "$aab"

  skip "16 KB aligned" "Play aligns the APKs it builds from an AAB"

  check_dex "$aab" 'base/dex/classes*.dex'
}

case "$platform" in
  ios)
    check_ios "${package%/}"
    ;;
  android)
    tools="$(find_build_tools)"
    export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
    export PATH="$JAVA_HOME/bin:$PATH"
    case "$package" in
      *.apk) check_apk "$package" ;;
      *.aab) check_aab "$package" ;;
      *) usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
