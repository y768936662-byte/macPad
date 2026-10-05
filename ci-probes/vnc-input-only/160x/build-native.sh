#!/usr/bin/env bash
set -euo pipefail
probe=$(cd "$(dirname "$0")" && pwd)
stage="$probe/source"
out="$probe/compile-output"
mkdir -p "$out/fixtures" "$out/libraries"
cp "$probe/source-manifest.json" "$out/source-manifest.json"
python3 - "$probe" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]); m=json.loads((p/'source-manifest.json').read_text())
for item in m['output_files']:
    candidate=(p/item['path']).resolve()
    assert candidate.is_relative_to(p.resolve())
    assert hashlib.sha256(candidate.read_bytes()).hexdigest()==item['sha256'],item['path']
assert m['patched_main_sha256']=='900e5bbf2a6b51cf6d09f6077e8f495ba06710ac73d3beae47d8c60ec32ac97d'
assert m['inputs_stable_after_capture'] is True
print('Verified complete reviewed source/fixture snapshot')
PY
sdk="$THEOS/sdks/iPhoneOS16.5.sdk"
test -d "$sdk"
{
  echo 'Compile-only; these binaries have not been deployed, admitted, or exercised on an iPad.'
  xcode-select -p
  xcrun clang --version
  xcrun --sdk iphoneos --show-sdk-version
  printf 'selected compile SDK: %s\n' "$sdk"
  git -C "$THEOS" rev-parse HEAD
  git -C "$THEOS" submodule status --recursive
  git -C "$RUNNER_TEMP/macpad-compile-sdks" rev-parse HEAD
  brew list --versions make ldid dpkg git-lfs
} > "$out/toolchain.txt"
make_args=(FINALPACKAGE=1 STRIP=0 OPTFLAG=-O2 \
  TARGET=iphone:clang:16.5:14.0 SDKVERSION=16.5 INCLUDE_SDKVERSION=16.5 \
  "SYSROOT=$sdk" "ISYSROOT=$sdk" \
  ADDITIONAL_LDFLAGS=-Wl,-ld_classic,-fixup_chains \
  THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 LIBMACHOOK_ON_DEVICE_BUILD=1)
# Query the actual pinned Theos make variables, not the requested directory.
cat > "$out/check-sdk.mk" <<'MAKE'
codex-check-build-sdk:
	@printf '%s\n' '$(SYSROOT)' '$(ISYSROOT)' '$(_THEOS_TARGET_SDK_VERSION)' '$(_THEOS_TARGET_INCLUDE_SDK_VERSION)'
MAKE
gmake --no-print-directory -s -C "$stage/libmachook" -f Makefile \
  -f "$out/check-sdk.mk" codex-check-build-sdk "${make_args[@]}" \
  > "$out/resolved-theos-sdk.txt"
python3 - "$out/resolved-theos-sdk.txt" "$sdk" <<'PY'
import sys
rows=open(sys.argv[1]).read().splitlines()
assert rows[-4:]==[sys.argv[2],sys.argv[2],'16.5','16.5'],rows
print('Actual Theos compile/link SDK roots resolved to pinned 16.5')
PY
gmake -C "$stage/libmachook" clean all "${make_args[@]}" messages=yes \
  2>&1 | tee "$out/native-build.log"
fat="$stage/libmachook/.theos/obj/libmachook.dylib"
test -f "$fat"
python3 - "$fat" <<'PY'
import subprocess,sys
arches=subprocess.check_output(['xcrun','lipo','-archs',sys.argv[1]],text=True).split()
assert len(arches)==2 and set(arches)=={'arm64','arm64e'},arches
print('Exact native library architectures verified: arm64 arm64e')
PY
cp "$fat" "$out/libraries/libmachook.compile-only.fat.dylib"
for arch in arm64 arm64e; do
  thin="$out/libraries/libmachook.$arch.compile-only.dylib"
  xcrun lipo "$fat" -thin "$arch" -output "$thin"
  xcrun otool -hv -l "$thin" > "$out/libraries/$arch.load-commands.txt"
  xcrun otool -L "$thin" > "$out/libraries/$arch.dependencies.txt"
  xcrun nm -u "$thin" > "$out/libraries/$arch.undefined-symbols.txt"
  python3 - "$thin" <<'PY'
import struct,sys
from pathlib import Path
data=Path(sys.argv[1]).read_bytes()
assert len(data)>=32
magic,cpu,subtype,kind,count,extent,flags,reserved=struct.unpack_from('<8I',data)
assert magic==0xfeedfacf and cpu==0x100000c and kind==6
assert count<=4096 and 32+extent<=len(data)
cursor=32; commands=[]
for _ in range(count):
    assert cursor+8<=32+extent
    cmd,size=struct.unpack_from('<2I',data,cursor)
    assert size>=8 and cursor+size<=32+extent
    commands.append(cmd); cursor+=size
assert cursor==32+extent
assert 0x80000034 in commands,'Missing LC_DYLD_CHAINED_FIXUPS'
assert 0x80000022 not in commands,'Classic LC_DYLD_INFO_ONLY is not the required artifact format'
print('Actual linked library has chained fixups and no classic fixup command')
PY
  for name in test_vnc_backend_selector test_vnc_namespace test_vnc_profile; do
    xcrun clang -target "$arch-apple-ios14.0" -isysroot "$sdk" \
      -std=c11 -Wall -Wextra -I"$stage/include" "$probe/fixtures/$name.c" \
      -o "$out/fixtures/$name.$arch.compile-only" \
      > "$out/fixtures/$name.$arch.compile.log" 2>&1
    actual=$(xcrun lipo -archs "$out/fixtures/$name.$arch.compile-only")
    test "$actual" = "$arch"
  done
  log="$out/fixtures/namespace-negative.$arch.log"
  if xcrun clang -target "$arch-apple-ios14.0" -isysroot "$sdk" \
      -std=c11 -I"$stage/include" -DMACWS_VNC_TEST_NAMESPACE_COLLISION \
      -fsyntax-only "$probe/fixtures/test_vnc_namespace.c" > "$log" 2>&1; then
    echo 'ERROR: namespace collision negative control unexpectedly compiled' >&2
    exit 1
  fi
  python3 - "$log" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
assert 'MacWSVNCReadExact' in s and re.search(r'redefinition|different kind|conflicting',s,re.I),s[:1000]
print('Native SDK namespace collision negative control rejected the intended symbol')
PY
done
# Host CPU controls run only portable header logic; they do not invoke hooks,
# SDK framework APIs, processes, sockets, or any device entry point.
for name in test_vnc_backend_selector test_vnc_namespace test_vnc_profile; do
  xcrun clang -std=c11 -Wall -Wextra -I"$stage/include" \
    "$probe/fixtures/$name.c" -o "$out/fixtures/$name.host-cpu" \
    > "$out/fixtures/$name.host-cpu.compile.log" 2>&1
done
{
  echo 'Host CPU header checks only, not ARM64e/device runtime acceptance'
  "$out/fixtures/test_vnc_backend_selector.host-cpu"
  "$out/fixtures/test_vnc_namespace.host-cpu"
  "$out/fixtures/test_vnc_profile.host-cpu" "$probe/fixtures/reviewed-vnc-load-commands.bin"
} > "$out/host-cpu-results.txt"
python3 - "$out" <<'PY'
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]); rows=[]
for f in sorted(x for x in p.rglob('*') if x.is_file()):
    rows.append({'path':f.relative_to(p).as_posix(),'bytes':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()})
(p/'compile-artifact-manifest.json').write_text(json.dumps({'scope':'compile-only; no native device runtime or trustcache acceptance','files':rows},indent=2)+'\n')
print('Compile-only artifact identities saved')
PY
