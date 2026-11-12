#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Builds dist/Halo.app. With --install, moves it to /Applications/Halo.app (replacing the old one) and opens it
# there, so Spotlight and launchers find exactly one Halo and a login item points at a stable place.
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift build --disable-sandbox -c release
task_bin_dir="$(swift build --disable-sandbox -c release --show-bin-path)"
task_app_path="$PWD/dist/Halo.app"
# Assembled from nothing each time, so nothing left from an earlier build is signed into this one.
rm -rf "$task_app_path"
mkdir -p "$task_app_path/Contents/MacOS" "$task_app_path/Contents/Resources"
cp "$task_bin_dir/Halo" "$task_app_path/Contents/MacOS/Halo"
# SwiftPM also writes this Mac's toolchain folders into the search path, ahead of Contents/Frameworks. On anyone else's
# Mac they are missing at best; keep only the system's Swift and the bundle's own places.
for task_rpath in ${(f)"$(otool -l "$task_app_path/Contents/MacOS/Halo" | awk '/cmd LC_RPATH/ { getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }')"}; do
  [[ "$task_rpath" == @* || "$task_rpath" == /usr/lib/* ]] || install_name_tool -delete_rpath "$task_rpath" "$task_app_path/Contents/MacOS/Halo"
done
cp packaging/Info.plist "$task_app_path/Contents/Info.plist"
# Regenerate with: swift scripts/make-icon.swift packaging/AppIcon.icns
cp packaging/AppIcon.icns "$task_app_path/Contents/Resources/AppIcon.icns"
# Interface text: English wording is the key and the default; the catalog adds zh-Hans and HaloTests checks it covers
# every key. The lproj folders hold the permission prompts (InfoPlist.strings).
for task_lproj in packaging/*.lproj; do
  cp -R "$task_lproj" "$task_app_path/Contents/Resources/"
done
xcrun xcstringstool compile packaging/Localizable.xcstrings --output-directory "$task_app_path/Contents/Resources"
# The agent skill the Diagnostics page links into ~/.agents/skills and ~/.claude/skills, so it follows the installed app.
cp -R packaging/AgentSkill "$task_app_path/Contents/Resources/"
# Sparkle, for updates. ditto keeps the framework's version symlinks, which cp -R would flatten and break its signature.
# Contents/Frameworks is where the rpath in Package.swift points and the only place codesign accepts a framework.
mkdir -p "$task_app_path/Contents/Frameworks"
ditto "$task_bin_dir/Sparkle.framework" "$task_app_path/Contents/Frameworks/Sparkle.framework"
# The licenses travel with the app: Halo's own (GPL-3.0) and Sparkle's (MIT, which asks for its notice in every copy).
task_sparkle_license=.build/artifacts/sparkle/Sparkle/LICENSE
[[ -f "$task_sparkle_license" ]] || { print -u2 "Sparkle's license was not found at $task_sparkle_license."; exit 1 }
mkdir -p "$task_app_path/Contents/Resources/Licenses"
cp LICENSE "$task_app_path/Contents/Resources/Licenses/Halo.txt"
cp "$task_sparkle_license" "$task_app_path/Contents/Resources/Licenses/Sparkle.txt"
# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc signatures change on every build. Developer
# ID first, the identity releases are signed with: with Halo's own, a build installed here is granted the same as a
# downloaded one and switching between them asks for nothing again. Then Apple Development; then ad-hoc.
task_identities="$({ security find-identity -v -p codesigning || true; })"
task_sign_identity="${HALO_SIGN_IDENTITY:-$(print -r -- "$task_identities" | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
task_sign_identity="${task_sign_identity:-$(print -r -- "$task_identities" | awk -F'"' '/Apple Development/ { print $2; exit }')}"
# With Developer ID, the hardened runtime too, as releases have it, so what runs here is what others run; no secure
# timestamp, which needs Apple's server (releases add it). Decided by the identity's name, also when HALO_SIGN_IDENTITY
# gives its hash. Set HALO_SIGN_OPTIONS (even empty) to choose otherwise.
task_identity_line=""
if [[ -n "$task_sign_identity" && "$task_sign_identity" != "-" ]]; then
  task_identity_line="$(print -r -- "$task_identities" | grep -F -- "$task_sign_identity" | head -1 || true)"
fi
if [[ -z "${HALO_SIGN_OPTIONS+set}" && ( "$task_sign_identity" == "Developer ID Application:"* || "$task_identity_line" == *'"Developer ID Application:'* ) ]]; then
  HALO_SIGN_OPTIONS="--options runtime --timestamp=none"
fi
# Said every time: a certificate that expired or went missing would quietly sign with another identity, and macOS
# would then ask for Accessibility again.
print -u2 "Signing as ${task_sign_identity:--}${HALO_SIGN_OPTIONS:+ ($HALO_SIGN_OPTIONS)}"
# Inside out, with Halo's identity: Sparkle's helpers, then the framework, then the app. Not --deep, which applies one
# set of options to everything and drops the helpers' own entitlements. HALO_SIGN_OPTIONS adds the release options
# (the release build adds the hardened runtime and a secure timestamp).
# The hardened runtime loads only frameworks signed by the same team, which an ad-hoc signature has none of.
if [[ ( -z "$task_sign_identity" || "$task_sign_identity" == "-" ) && "${HALO_SIGN_OPTIONS:-}" == *runtime* ]]; then
  print -u2 "HALO_SIGN_OPTIONS asks for the hardened runtime, but there is no signing identity; Halo could not load Sparkle."
  exit 1
fi
task_sign() { codesign --force ${=HALO_SIGN_OPTIONS:-} --sign "${task_sign_identity:--}" "$@" }
task_sparkle="$task_app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
for task_xpc in "$task_sparkle"/XPCServices/*.xpc(N); do task_sign --preserve-metadata=entitlements "$task_xpc"; done
for task_nested in "$task_sparkle/Autoupdate" "$task_sparkle/Updater.app"; do [[ -e "$task_nested" ]] && task_sign "$task_nested"; done
task_sign "$task_sparkle"
task_sign --identifier com.liuzhekan.Halo "$task_app_path"
codesign --verify --deep --strict "$task_app_path"
print "$task_app_path"
if [[ "${1:-}" == "--install" ]]; then
  task_installed="/Applications/Halo.app"
  task_staged="/Applications/.Halo.app.installing"
  task_previous="/Applications/.Halo.app.previous"
  # Ask by bundle ID: a command-line build of Halo is not the app, and telling a stopped app to quit would launch it.
  task_running() { [[ "$(osascript -e 'application id "com.liuzhekan.Halo" is running')" == "true" ]] }
  if task_running; then
    osascript -e 'tell application id "com.liuzhekan.Halo" to quit' >/dev/null
    for _ in {1..40}; do task_running || break; sleep 0.25; done
    if task_running; then
      print -u2 "Halo is still running (an open alert can hold it). Quit it, then run this again; nothing was replaced."
      exit 1
    fi
  fi
  # Left by a run that could not move it back, it is the only copy: keep it rather than delete it.
  if [[ -e "$task_previous" && ! -e "$task_installed" ]]; then
    print -u2 "The previous Halo is at $task_previous from an earlier failed install; move it back to $task_installed, then run this again."
    exit 1
  fi
  # Copy beside the old app first, so a failed copy leaves the installed Halo untouched.
  rm -rf "$task_staged"
  ditto "$task_app_path" "$task_staged"
  # Then swap: the old app steps aside and comes back if the new one cannot take its place.
  rm -rf "$task_previous"
  [[ -e "$task_installed" ]] && mv "$task_installed" "$task_previous"
  if ! mv "$task_staged" "$task_installed"; then
    if [[ -e "$task_previous" ]]; then
      if mv "$task_previous" "$task_installed"; then
        print -u2 "Could not put the new Halo in place; the previous one is back."
      else
        print -u2 "Could not put the new Halo in place, nor move the previous one back: it is at $task_previous. Move it back before running this again."
      fi
    else
      print -u2 "Could not put the new Halo in place; nothing was installed."
    fi
    exit 1
  fi
  rm -rf "$task_previous" "$task_app_path"
  open "$task_installed"
  print "$task_installed"
fi
