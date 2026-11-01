#!/usr/bin/env bash
# Check what `make release-assets` left in build/release/ before it is published.
#
#   scripts/check-release-assets.sh VERSION                 ad-hoc build (PR dry run)
#   scripts/check-release-assets.sh VERSION --team TEAMID   Developer ID build, notarized and stapled
#
# Always: checksums match, the DMG verifies, the app and the CLI are universal (arm64 + x86_64), the
# bundle carries VERSION, the app's signature verifies. With --team: the app, the CLI and the DMG are
# signed by that team with the hardened runtime, the DMG has a stapled ticket and Gatekeeper accepts the
# app and the DMG as notarized.
set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 VERSION [--team TEAMID]" >&2; exit 64; }
version="$1"
shift
team=""
while [ $# -gt 0 ]; do
    case "$1" in
        --team)
            [ $# -ge 2 ] || { echo "check-release-assets: --team needs a value" >&2; exit 64; }
            team="$2"
            shift
            ;;
        *) echo "check-release-assets: unknown argument: $1" >&2; exit 64 ;;
    esac
    shift
done

root="$(git rev-parse --show-toplevel)"
release="$root/build/release"
app="$root/build/OpenClean.app"
dmg="$release/OpenClean-$version.dmg"
cli_zip="$release/openclean-cli-$version.zip"

fail() { echo "::error::$*" >&2; exit 1; }

(cd "$release" && shasum -a 256 -c SHA256SUMS.txt)
hdiutil verify "$dmg"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/check-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
ditto -x -k "$cli_zip" "$work"
cli="$work/openclean-cli/bin/openclean"
[ -x "$cli" ] || fail "$cli_zip has no openclean-cli/bin/openclean"

for binary in "$app/Contents/MacOS/OpenClean" "$cli"; do
    archs="$(lipo -archs "$binary")"
    echo "$binary: $archs"
    case " $archs " in *" arm64 "*) ;; *) fail "$binary lacks arm64" ;; esac
    case " $archs " in *" x86_64 "*) ;; *) fail "$binary lacks x86_64" ;; esac
done

/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" | grep -qx "$version" ||
    fail "the app bundle is not stamped with $version"
"$cli" --version | grep -q "$version" || fail "the CLI does not report $version"
for lang in de es fr ja zh-Hans; do
    [ -f "$app/Contents/Resources/$lang.lproj/Localizable.strings" ] || fail "the app has no $lang translations"
    [ -d "$app/Contents/Resources/OpenClean_OpenCleanAppModel.bundle" ] || fail "the app lacks the OpenCleanAppModel resource bundle"
done
codesign --verify --deep --strict --verbose=2 "$app"

[ -n "$team" ] || exit 0

# team_of PATH: the TeamIdentifier codesign reports, or "not set".
team_of() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
for signed in "$app" "$cli" "$dmg"; do
    [ "$(team_of "$signed")" = "$team" ] || fail "$signed is not signed by team $team"
done
for code in "$app" "$cli"; do
    codesign -dv "$code" 2>&1 | grep -q 'flags=.*runtime' || fail "$code lacks the hardened runtime"
done
codesign --verify --strict --verbose=2 "$cli"
codesign --verify --verbose=2 "$dmg"
# stapler validate asks Apple's ticket server too; a dropped connection fails it (error 68) even
# when the ticket is stapled, so it is retried like the staple step in release.yml.
for attempt in 1 2 3 4 5; do
    xcrun stapler validate "$dmg" && break
    [ "$attempt" != 5 ] || fail "stapler could not validate $dmg"
    echo "stapler validate failed, retrying in $((attempt * 20)) s"
    sleep $((attempt * 20))
done
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg" 2>&1 | tee "$work/spctl-dmg.txt"
grep -q 'source=Notarized Developer ID' "$work/spctl-dmg.txt" || fail "Gatekeeper does not see the DMG as notarized"
spctl --assess --type execute --verbose=2 "$app" 2>&1 | tee "$work/spctl-app.txt"
grep -q 'source=Notarized Developer ID' "$work/spctl-app.txt" || fail "Gatekeeper does not see the app as notarized"
