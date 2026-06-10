#!/usr/bin/env bash
#
# go-cmp/mayhem/build.sh — build google/go-cmp's OSS-Fuzz Go fuzz target as a sanitized
# libFuzzer binary, REPLICATING OSS-Fuzz's compile_native_go_fuzzer.
#
# OSS-Fuzz target (projects/go-cmp/build.sh):
#   cp $SRC/fuzz_test.go ./cmp/
#   go mod tidy
#   printf "package cmp\nimport _ \"github.com/AdamKorcz/go-118-fuzz-build/testing\"\n" > register.go
#   go mod tidy
#   compile_native_go_fuzzer github.com/google/go-cmp/cmp FuzzDiff FuzzDiff
#
# i.e. the NATIVE go test fuzz harness `func FuzzDiff(f *testing.F)` (mayhem/fuzz_test.go.src),
# built with go-118-fuzz-build (which rewrites the stdlib `testing` import to the AdamKorcz
# shim), then linked with $LIB_FUZZING_ENGINE.
#
# The harness exercises cmp.Diff over two arbitrary []byte values — the public value-comparison
# entry point of the package.
#
# We produce:
#   /mayhem/FuzzDiff   — OSS-Fuzz target (cmp.FuzzDiff, go-118-fuzz-build, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by go-118-fuzz-build); we link it against
# the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_native_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

# Go env: toolchain + caches are under /opt/toolchains (pinned by Dockerfile ENV).
# Ensure PATH includes the toolchain bin dirs for standalone invocations.
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

# The OSS-Fuzz harness (func FuzzDiff) is part of package cmp. OSS-Fuzz copies fuzz_test.go into
# ./cmp/; replicate that so go-118-fuzz-build sees FuzzDiff in the cmp package.
cp "$SRC/mayhem/fuzz_test.go.src" "$SRC/cmp/fuzz_test.go"

# go-118-fuzz-build needs the AdamKorcz testing shim registered as a module dep. The blank import
# in register.go (package cmp, repo root) anchors the dependency so `go mod tidy` keeps it.
# Order: tidy first (resolves existing deps from cache), then go get the shim (offline-first via
# GOPROXY file proxy), then NO trailing tidy (it would prune the shim — nothing statically imports it
# until the builder generates the entrypoint at build time).
printf 'package cmp\nimport _ "github.com/AdamKorcz/go-118-fuzz-build/testing"\n' > "$SRC/register.go"
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: cmp.FuzzDiff via go-118-fuzz-build (NATIVE *testing.F harness) ─────────────
#     Exact replica of `compile_native_go_fuzzer github.com/google/go-cmp/cmp FuzzDiff FuzzDiff`.
echo "=== building FuzzDiff (cmp.FuzzDiff, go-118-fuzz-build) ==="
go-118-fuzz-build -o "$SRC/mayhem-build/FuzzDiff.a" -func FuzzDiff \
    github.com/google/go-cmp/cmp
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/FuzzDiff.a" -o /mayhem/FuzzDiff
echo "built /mayhem/FuzzDiff"

echo "build.sh complete:"
ls -la /mayhem/FuzzDiff 2>&1 || true
