#!/bin/bash
# Lane MACREL-1: the macOS Apple Silicon package of a release, built on the Mac build host (docs/RELEASE.md, "The Mac package").
# tools/release/autorelease.sh runs it from the Deck; nothing is signed on the Mac (the release key never leaves the Deck: the Deck checks
# what comes back and signs manifest-macos.json itself).
#
#   tools/release/build_macos_release.sh --check
#       the host answers over ssh (BatchMode, 20 s connect timeout) and has what a build needs: its CI environment (~/<root>/env.sh),
#       cmake / ninja / clang / codesign / lipo / rsync / git, Python 3.10 or later, Godot 4.7.2 (~/<root>/tools/Godot.app), the
#       official 4.7.2 export templates with package_macos_preview.py's pinned SHA-256, the CI repository and the godot-cpp mirror.
#       Prints "MAC READY <host> ..." and exits 0, or names what is missing and exits 1 (2 when the host does not answer).
#   tools/release/build_macos_release.sh <checkout at the release tag> <version> <out dir>
#       pushes the tag to the host's private CI repository (~/<root>/repo.git), fetches it there into a fresh repository (git's
#       transport, never a local clone that copies repo.git's files: RELCAND-1) and checks it out (godot-cpp from the host's
#       mirror) and runs tools/release/package_macos.py in the host's slot 0 (as a lane job: a fresh arm64 build, macOS 13 minimum, the
#       Godot export, ad-hoc signing, the strict audit), then fetches the package folder into <out dir>: <stem>.zip, <stem>.zip.sha256,
#       <stem>.inventory.txt and README-MAC.txt (autorelease.sh checks that set exactly). The clone and the tag are removed from the host
#       afterwards, also on a failure.
# Environment: OPENBFME_RELEASE_MAC_HOST (mac: the Mac build host's ssh alias), OPENBFME_RELEASE_MAC_JOBS (10);
#   required, from the operator's private release environment (merge queue q21, as PUBLISH-2 keeps private paths out of the public
#   tree): OPENBFME_RELEASE_MAC_ROOT, <root> above: the host's CI folder, relative to its home;
#   OPENBFME_RELEASE_MAC_SSH (tests only: autorelease.sh accepts it in stand-in mode only) replaces ssh.
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HOST=${OPENBFME_RELEASE_MAC_HOST:-mac}
SSH=${OPENBFME_RELEASE_MAC_SSH:-ssh}
JOBS=${OPENBFME_RELEASE_MAC_JOBS:-10}
ROOT=${OPENBFME_RELEASE_MAC_ROOT:-}
HB=/opt/homebrew/bin   # the host's Homebrew bash 5 / git / rsync (macOS's own bash is 3.2, its rsync is openrsync)
fail() { echo "MAC BUILD FAIL: $*" >&2; exit 1; }
[[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || fail "OPENBFME_RELEASE_MAC_HOST '$HOST' is not a host name"
[[ "$JOBS" =~ ^[1-9][0-9]?$ ]] || fail "OPENBFME_RELEASE_MAC_JOBS '$JOBS' is not a job count"
[ -n "$ROOT" ] || fail "OPENBFME_RELEASE_MAC_ROOT is not set (the operator's private release environment: the Mac host's CI folder)"
[[ "$ROOT" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] && [[ ! "$ROOT" =~ (^|/)\.\.?(/|$) ]] || fail "OPENBFME_RELEASE_MAC_ROOT is not a folder relative to the host's home"
remote() { $SSH -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=60 "$HOST" "$HB/bash -s"; }
TEMPLATE_SHA256=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import package_macos_preview as p; print(p.TEMPLATE_SHA256)' "$HERE")

if [ "${1:-}" = --check ]; then
  [ $# = 1 ] || fail "--check takes no arguments"
  read -r -d '' CHECK <<EOS || true
set -u
. "\$HOME/$ROOT/env.sh" || { echo "MAC NOT READY: no ~/$ROOT/env.sh"; exit 1; }
for t in cmake ninja clang codesign lipo rsync git shasum python3; do command -v \$t >/dev/null || { echo "MAC NOT READY: \$t is not on the CI PATH"; exit 1; }; done
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "MAC NOT READY: python3 is \$(python3 --version 2>&1), 3.10 or later is needed"; exit 1; }
G=\$C/tools/Godot.app/Contents/MacOS/Godot
[ -x "\$G" ] || { echo "MAC NOT READY: no Godot at ~/$ROOT/tools/Godot.app"; exit 1; }
v=\$("\$G" --headless --version 2>/dev/null | tail -1)
case "\$v" in 4.7.2.stable.*) ;; *) echo "MAC NOT READY: Godot is '\$v', not 4.7.2.stable"; exit 1 ;; esac
T=\$C/tools/Godot_v4.7.2-stable_export_templates.tpz
[ -f "\$T" ] && [ "\$(shasum -a 256 "\$T" | cut -d' ' -f1)" = $TEMPLATE_SHA256 ] || { echo "MAC NOT READY: the Godot 4.7.2 export templates (~/$ROOT/tools/Godot_v4.7.2-stable_export_templates.tpz) are missing or not the pinned file"; exit 1; }
[ -d "\$C/repo.git" ] && [ -d "\$C/godot-cpp.git" ] || { echo "MAC NOT READY: no CI repository or godot-cpp mirror in ~/$ROOT"; exit 1; }
echo "MAC READY \$(sw_vers -productVersion) \$(uname -m) Godot \$v"
EOS
  rc=0; out=$(printf '%s\n' "$CHECK" | remote 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^/  mac: /'
  if [ $rc = 0 ] && printf '%s\n' "$out" | grep '^MAC READY ' >/dev/null; then echo "MAC READY $HOST"; exit 0; fi
  if [ $rc = 255 ]; then echo "MAC BUILD FAIL: the Mac build host '$HOST' does not answer over ssh (asleep, lid closed, off the network?)" >&2; exit 2; fi
  fail "the Mac build host '$HOST' is not ready (above)"
fi

[ $# = 3 ] || fail "usage: build_macos_release.sh --check | <checkout at the release tag> <version> <out dir>"
WT=$1; VERSION=$2; OUT=$3
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|nightly|preview)\.[0-9]+)?$ ]] || fail "$VERSION is not a release version"
COMMIT=$(git -C "$WT" rev-parse -q --verify "refs/tags/$VERSION^{commit}") || fail "$WT has no tag $VERSION"
[ "$(git -C "$WT" rev-parse HEAD)" = "$COMMIT" ] || fail "$WT is not checked out at $VERSION"
[ -d "$OUT" ] && [ -z "$(ls -A "$OUT")" ] || fail "$OUT must be an empty folder"
STEM="openbfme-$VERSION-macos-arm64"
cleanup() {
  echo "MAC BUILD: removing the clone and the tag $VERSION on $HOST"
  remote <<EOS || echo "MAC BUILD: the cleanup on $HOST failed: remove ~/$ROOT/release/$VERSION and the tag $VERSION of ~/$ROOT/repo.git by hand"
rm -rf "\$HOME/$ROOT/release/$VERSION"; git -C "\$HOME/$ROOT/repo.git" tag -d $VERSION >/dev/null 2>&1; true
EOS
}
trap cleanup EXIT
echo "MAC BUILD: $VERSION ($COMMIT) on $HOST"
GIT_SSH_COMMAND="$SSH -o BatchMode=yes -o ConnectTimeout=20" git -C "$WT" push -q -f --receive-pack="$HB/git-receive-pack" \
  "$HOST:$ROOT/repo.git" "refs/tags/$VERSION:refs/tags/$VERSION" || fail "pushing $VERSION to $HOST failed"
remote <<EOS || fail "the package build on $HOST failed (above)"
set -euo pipefail
. "\$HOME/$ROOT/env.sh"
R=\$C/release/$VERSION
# the Mac's slot 0, as a lane job takes it (ci_heavy): a gate or measurement there finishes first
exec 6>\$C/verify.lock.0; flock -n 6 || { echo "MAC BUILD: waiting for the Mac's slot 0 (a gate or lane job holds it)"; flock 6; }
rm -rf "\$R"; mkdir -p "\$R/out"
# RELCAND-1: an empty repository that fetches the tag alone over git's transport (file://), never a local clone: a local clone copies or
# hardlinks repo.git's object files and died with "hardlink different from source at .../objects/pack/tmp_pack_..." (v0.4.11) while
# another job was writing a pack there; the transport reads objects through git and never sees a pack being written
git init -q "\$R/src"
cd "\$R/src"
git fetch -q --no-tags "file://\$C/repo.git" "refs/tags/$VERSION:refs/tags/$VERSION"
git checkout -q --detach "$VERSION"
[ "\$(git rev-parse HEAD)" = $COMMIT ] || { echo "MAC BUILD: the clone is not at $COMMIT"; exit 1; }
d=\$(git describe --tags --match 'v[0-9]*' --exclude '*-playtest.*' --always --dirty --abbrev=10)
[ "\$d" = $VERSION ] || { echo "MAC BUILD: the clone describes as \$d, not $VERSION"; exit 1; }
git -c protocol.file.allow=always submodule update -q --init --reference "\$C/godot-cpp.git" engine/thirdparty/godot-cpp
echo "MAC BUILD: package_macos.py (a fresh arm64 build with -j$JOBS, the export, ad-hoc signing, the strict audit)"
if ! nice -n 10 python3 tools/release/package_macos.py --version $VERSION --godot "\$C/tools/Godot.app/Contents/MacOS/Godot" \
     --templates "\$C/tools/Godot_v4.7.2-stable_export_templates.tpz" --out "\$R/out" --jobs $JOBS > "\$R/package.log" 2>&1; then
  tail -60 "\$R/package.log"; exit 1
fi
grep -E '^(MACOS|PACKAGE|AUDIT)' "\$R/package.log" || true
ls -l "\$R/out"
EOS
rsync -a -e "$SSH -o BatchMode=yes" --rsync-path="$HB/rsync" --exclude='.*' "$HOST:$ROOT/release/$VERSION/out/" "$OUT/" \
  || fail "fetching the package from $HOST failed"
echo "MAC BUILD: fetched $(cd "$OUT" && ls | tr '\n' ' ')"
[ -f "$OUT/$STEM.zip" ] || fail "$HOST returned no $STEM.zip"
