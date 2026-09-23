#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../libexec/steamos-waydroid/lib/target-fingerprint.sh
source "$REPO_ROOT/libexec/steamos-waydroid/lib/target-fingerprint.sh"
# shellcheck source=../libexec/steamos-waydroid/lib/kernel-capabilities.sh
source "$REPO_ROOT/libexec/steamos-waydroid/lib/kernel-capabilities.sh"
# shellcheck source=../libexec/steamos-waydroid/lib/bundle-compatibility.sh
source "$REPO_ROOT/libexec/steamos-waydroid/lib/bundle-compatibility.sh"

TEST_ROOT="$(mktemp -d)"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT
fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

write_fingerprint() {
	local path="$1" version="$2" build="$3" kernel="$4" abi="$5"
	cat >"$path" <<EOF
STEAMOS_VERSION_ID=$version
STEAMOS_BUILD_ID=$build
KERNEL_RELEASE=$kernel
ABI_SHA256=$abi
EOF
}

ABI_A="$(printf 'a%.0s' {1..64})"
ABI_B="$(printf 'b%.0s' {1..64})"
EXPECTED="$TEST_ROOT/expected.env"
CURRENT="$TEST_ROOT/current.env"
MOCK_BIN="$TEST_ROOT/bin"
MODULES_ROOT="$TEST_ROOT/modules"
mkdir -p "$MOCK_BIN" "$MODULES_ROOT/test-kernel"
cat >"$MOCK_BIN/modinfo" <<'EOF'
#!/usr/bin/env bash
[[ ${MOCK_BINDER_BUILTIN:-false} == true ]] && printf '(builtin)\n'
EOF
chmod +x "$MOCK_BIN/modinfo"
export STEAMOS_WAYDROID_MODINFO="$MOCK_BIN/modinfo"
export STEAMOS_WAYDROID_KERNEL_RELEASE=test-kernel
export STEAMOS_WAYDROID_MODULES_ROOT="$MODULES_ROOT"

write_fingerprint "$EXPECTED" 3.8.0 build-a test-kernel "$ABI_A"
write_fingerprint "$CURRENT" 3.8.0 build-a test-kernel "$ABI_A"
MOCK_BINDER_BUILTIN=false bundle_compatibility "$EXPECTED" "$CURRENT" |
	grep -Fxq exact || fail 'same version/build and ABI was not exact'

write_fingerprint "$CURRENT" 3.8.1 build-b other-kernel "$ABI_A"
MOCK_BINDER_BUILTIN=true bundle_compatibility "$EXPECTED" "$CURRENT" |
	grep -Fxq abi-compatible || fail 'matching ABI with built-in Binder was not ABI-compatible'

write_fingerprint "$CURRENT" 3.8.1 build-b test-kernel "$ABI_A"
MOCK_BINDER_BUILTIN=false bundle_compatibility "$EXPECTED" "$CURRENT" |
	grep -Fxq abi-compatible ||
	fail 'matching ABI and kernel without built-in Binder was not ABI-compatible'

write_fingerprint "$CURRENT" 3.8.1 build-b other-kernel "$ABI_A"
MOCK_BINDER_BUILTIN=false bundle_compatibility "$EXPECTED" "$CURRENT" |
	grep -Fxq incompatible || fail 'matching ABI without built-in Binder was accepted'

write_fingerprint "$CURRENT" 3.8.1 build-b other-kernel "$ABI_B"
MOCK_BINDER_BUILTIN=true bundle_compatibility "$EXPECTED" "$CURRENT" |
	grep -Fxq incompatible || fail 'different ABI with built-in Binder was accepted'

# Exercise the checker copied into bundles: this is also the launcher's runtime
# validation path after an ABI-compatible bundle has been selected.
CHECK_ROOT="$TEST_ROOT/check"
BUNDLE_ROOT="$CHECK_ROOT/bundle"
mkdir -p "$CHECK_ROOT/tools" "$BUNDLE_ROOT"
cp "$REPO_ROOT/libexec/steamos-waydroid/check-bundle-target.sh" "$CHECK_ROOT/tools/"
cp "$REPO_ROOT/libexec/steamos-waydroid/lib/"*.sh "$CHECK_ROOT/tools/"
chmod +x "$CHECK_ROOT/tools/check-bundle-target.sh"
cat >"$TEST_ROOT/os-release" <<'EOF'
ID=steamos
VERSION_ID=3.8.1
BUILD_ID=build-b
EOF
cat >"$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'test-kernel\n'
EOF
cat >"$MOCK_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -Q ]] || exit 1
printf '%s 1.0-1\n' "$2"
EOF
chmod +x "$MOCK_BIN/uname" "$MOCK_BIN/pacman"
PATH="$MOCK_BIN:$PATH" TARGET_OS_RELEASE_FILE="$TEST_ROOT/os-release" \
	collect_target_fingerprint "$CURRENT"
cp "$CURRENT" "$BUNDLE_ROOT/target-fingerprint.env"
sed -i 's/^STEAMOS_VERSION_ID=.*/STEAMOS_VERSION_ID=3.8.0/; s/^STEAMOS_BUILD_ID=.*/STEAMOS_BUILD_ID=build-a/' \
	"$BUNDLE_ROOT/target-fingerprint.env"
checker_output="$(PATH="$MOCK_BIN:$PATH" \
	TARGET_OS_RELEASE_FILE="$TEST_ROOT/os-release" MOCK_BINDER_BUILTIN=true \
	STEAMOS_WAYDROID_MODINFO="$MOCK_BIN/modinfo" \
	STEAMOS_WAYDROID_KERNEL_RELEASE=test-kernel \
	STEAMOS_WAYDROID_MODULES_ROOT="$MODULES_ROOT" \
	"$CHECK_ROOT/tools/check-bundle-target.sh" "$BUNDLE_ROOT")"
grep -Fq 'ABI-compatible bundle match' <<<"$checker_output" ||
	fail 'ABI-compatible bundle failed runtime target validation'

make_candidate() {
	local name="$1" state="$2"
	local root="$TEST_ROOT/home/.local/opt/steamos-waydroid/builds/$name"
	mkdir -p "$root/bin" "$root/tools"
	: >"$root/.verified"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$root/bin/cage"
	cp "$root/bin/cage" "$root/bin/wlr-randr"
	cat >"$root/tools/check-bundle-target.sh" <<EOF
#!/usr/bin/env bash
if [[ \${2:-} == --compatibility-state ]]; then
	printf '%s\\n' '$state'
	[[ '$state' != incompatible ]]
else
	[[ '$state' == exact ]]
fi
EOF
	chmod +x "$root/bin/cage" "$root/bin/wlr-randr" "$root/tools/check-bundle-target.sh"
}

make_candidate z-abi abi-compatible
make_candidate a-exact exact
PROJECT_ROOT="$TEST_ROOT/home/.local/opt/steamos-waydroid"
ln -sfn builds/z-abi "$PROJECT_ROOT/current"
HOME="$TEST_ROOT/home" "$REPO_ROOT/extras/scripts/select-bundle" >/dev/null
[[ "$(basename -- "$(readlink -f "$PROJECT_ROOT/current")")" == a-exact ]] ||
	fail 'exact candidate did not beat ABI-compatible candidate'
rm -rf -- "$PROJECT_ROOT/builds/a-exact"
make_candidate a-abi abi-compatible
HOME="$TEST_ROOT/home" "$REPO_ROOT/extras/scripts/select-bundle" >/dev/null
[[ "$(basename -- "$(readlink -f "$PROJECT_ROOT/current")")" == z-abi ]] ||
	fail 'multiple ABI-compatible candidates were not selected deterministically'

make_candidate z-abi incompatible
make_candidate a-abi incompatible
printf 'z-abi\n' >"$PROJECT_ROOT/allow-target-mismatch"
HOME="$TEST_ROOT/home" "$REPO_ROOT/extras/scripts/select-bundle" \
	>/dev/null 2>"$TEST_ROOT/override-output" ||
	fail 'explicit target mismatch override was not preserved'
grep -Fq 'explicitly allowed target mismatch' "$TEST_ROOT/override-output" ||
	fail 'explicit override was not reported separately from ABI compatibility'

printf 'ok - bundle compatibility states, priority, and runtime validation\n'
