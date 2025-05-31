#!/bin/sh -e
# Pack and creates multibinary executables

# Validate required tools
for cmd in go gzip tail head cut grep wc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' not found"
        exit 1
    fi
done

# TODO: Using gz for now due to upx isn't working on macos
# as expected and seems related to the code signature issues.
# GZ is used due to it's speed, compatibility and quite small binary size.
# You can set it to 'raw', 'upx' or 'xz' as well
[ "x${PKG_SUFFIX}" != 'x' ] || PKG_SUFFIX='gz'  # To use general xz archiver

name=ansiblego
suffixes="linux-amd64 linux-arm64 windows-amd64 darwin-amd64 darwin-arm64"

# Running static code checks
if [ -x "./check.sh" ]; then
    ./check.sh || exit $?
else
    echo "Warning: check.sh not found or not executable"
fi

# Disabling cgo in order to not link with libc and utilize static linkage binaries
# which will help to not relay on glibc on linux and be truely independend from OS
export CGO_ENABLED=0

# Build all binaries in parallel
echo "Building binaries..."
build_pids=""
for suffix in $suffixes; do
    echo "--> Build binary for ${suffix}"
    # Utilizing a number of optimizations to reduce the exec binary size
    GOOS="$(echo "${suffix}" | cut -d- -f1)" GOARCH="$(echo "${suffix}" | cut -d- -f2)" \
        go build -ldflags="-s -w" -gcflags=all="-l -B" -a -o "${name}.raw.${suffix}" "./cmd/${name}" &
    build_pids="$build_pids $!"
done

# Wait for all builds to complete and check for errors
failed=0
for pid in $build_pids; do
    if ! wait $pid; then
        echo "Error: Build process $pid failed"
        failed=1
    fi
done

if [ $failed -ne 0 ]; then
    echo "Error: One or more builds failed"
    exit 1
fi

if [ "x${PKG_SUFFIX}" != 'xraw' ] ; then
    # Pack all the executables
    echo "Packing binaries..."
    pack_pids=""
    for exec_suffix in $suffixes; do
        bin_name="${name}.raw.${exec_suffix}"
        out_name="${name}.${PKG_SUFFIX}.${exec_suffix}"

        # Check if source binary exists
        if [ ! -f "${bin_name}" ]; then
            echo "Error: Source binary ${bin_name} not found"
            exit 1
        fi

        # Run the packers only if the results are older than raw binary
        if [ ! -f "${out_name}" ] || [ "${bin_name}" -nt "${out_name}" ]; then
            if [ "x${PKG_SUFFIX}" = 'xupx' ] ; then
                if command -v upx >/dev/null 2>&1; then
                    echo "--> UPX pack binary for ${exec_suffix}"
                    upx --brute -q -9 -o "${out_name}" "${bin_name}" &
                    pack_pids="$pack_pids $!"
                else
                    echo "Warning: upx not found, copying raw binary"
                    cp "${bin_name}" "${out_name}"
                fi
            elif [ "x${PKG_SUFFIX}" = 'xxz' ] ; then
                if command -v xz >/dev/null 2>&1; then
                    echo "--> XZ pack binary for ${exec_suffix}"
                    xz -z -9e -T0 -c "${bin_name}" > "${out_name}" &
                    pack_pids="$pack_pids $!"
                else
                    echo "Warning: xz not found, using gzip instead"
                    gzip -9 -c "${bin_name}" > "${out_name}"
                fi
            elif [ "x${PKG_SUFFIX}" = 'xgz' ] ; then
                echo "--> Gzip pack binary for ${exec_suffix}"
                gzip -9 -c "${bin_name}" > "${out_name}" &
                pack_pids="$pack_pids $!"
            fi
        fi
    done

    # Wait for all packing to complete
    for pid in $pack_pids; do
        if ! wait $pid; then
            echo "Error: Packing process $pid failed"
            exit 1
        fi
    done
fi

# Combine the archs together
echo "Combining binaries..."
for out_suffix in $suffixes; do
    echo "--> Combining binaries for ${out_suffix}"
    out_bin="${name}.out.${out_suffix}"
    [ "x$(echo "${out_suffix}" | cut -d- -f1)" != "xwindows" ] || out_bin="${out_bin}.exe"

    # Select the appropriate binary based on package type
    if [ "x${PKG_SUFFIX}" = 'xraw' ] || [ "x${PKG_SUFFIX}" = 'xupx' ] ; then
        # RAW and UPX can be used as is
        cp -a "${name}.${PKG_SUFFIX}.${out_suffix}" "${out_bin}"
    else
        # We can't use xz/gz binary as the host one
        cp -a "${name}.raw.${out_suffix}" "${out_bin}"
    fi

    # Combine with the rest of the archs
    for pack_suffix in $suffixes; do
        [ "x${out_suffix}" != "x${pack_suffix}" ] || continue
        echo "-->   + ${pack_suffix}"
        pack_bin="${name}.${PKG_SUFFIX}.${pack_suffix}"

        if [ ! -f "${pack_bin}" ]; then
            echo "Error: Packed binary ${pack_bin} not found"
            exit 1
        fi

        echo '' >> "${out_bin}"
        echo "--- EMBEDDED_BINARY ${pack_suffix} ${PKG_SUFFIX} ---" >> "${out_bin}"
        cat "${pack_bin}" >> "${out_bin}"
    done
done

# Combine the sh bundle
echo "--> Combining binaries to shell bundle"
out_bin="${name}.out.sh.bundle"

if [ ! -f "unix_bundle.sh.head" ]; then
    echo "Error: unix_bundle.sh.head not found"
    exit 1
fi

cp -a unix_bundle.sh.head "${out_bin}"
chmod +x "${out_bin}"

for pack_suffix in $suffixes; do
    echo "-->   + ${pack_suffix}"
    pack_bin="${name}.${PKG_SUFFIX}.${pack_suffix}"

    if [ ! -f "${pack_bin}" ]; then
        echo "Error: Packed binary ${pack_bin} not found"
        exit 1
    fi

    echo '' >> "${out_bin}"
    echo "--- EMBEDDED_BINARY ${pack_suffix} ${PKG_SUFFIX} ---" >> "${out_bin}"
    cat "${pack_bin}" >> "${out_bin}"
done

echo "Build completed successfully!"
echo "Output files:"
ls -la "${name}.out."* 2>/dev/null || echo "No output files found"
