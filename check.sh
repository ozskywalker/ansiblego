#!/bin/sh
# Script to simplify the style check process

errors=0

echo
echo '---------------------- Custom Checks ----------------------'
echo
for f in $(git ls-files); do
    # Check text files
    if file "$f" 2>/dev/null | grep -q 'text$'; then
        # Ends with newline as POSIX requires
        if [ -n "$(tail -c 1 "$f" 2>/dev/null)" ]; then
            echo "Not ends with newline: $f"
            errors=$((errors + 1))
        fi
    fi
done

echo
echo '---------------------- GoFmt verify ----------------------'
echo
if command -v gofmt >/dev/null 2>&1; then
    reformat=$(gofmt -l .)
    if [ -n "${reformat}" ]; then
        echo "Please run 'gofmt -w .':"
        echo "${reformat}"
        errors=$((errors + $(echo "${reformat}" | wc -l)))
    fi
else
    echo "Warning: gofmt not found, skipping format check"
fi

echo
echo '---------------------- GoModTidy verify ----------------------'
echo
if [ -f "go.mod" ] && [ -f "go.sum" ] && command -v go >/dev/null 2>&1; then
    # Create temporary directory for safety
    tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'gotidy')
    trap "rm -rf '$tmp_dir'" EXIT

    # Save original files
    cp -f go.mod go.sum "$tmp_dir/"

    # Get original modification times using portable method
    if command -v stat >/dev/null 2>&1; then
        # Try GNU stat first, then BSD stat
        orig_mod_time=$(stat -c %Y go.mod 2>/dev/null || stat -f %m go.mod 2>/dev/null || echo "0")
        orig_sum_time=$(stat -c %Y go.sum 2>/dev/null || stat -f %m go.sum 2>/dev/null || echo "0")
    else
        # Fallback: just mark as different to force check
        orig_mod_time="1"
        orig_sum_time="1"
    fi

    # Run go mod tidy
    tidy_output=$(go mod tidy -v 2>&1)
    tidy_exit=$?

    # Get new modification times
    if command -v stat >/dev/null 2>&1; then
        new_mod_time=$(stat -c %Y go.mod 2>/dev/null || stat -f %m go.mod 2>/dev/null || echo "1")
        new_sum_time=$(stat -c %Y go.sum 2>/dev/null || stat -f %m go.sum 2>/dev/null || echo "1")
    else
        new_mod_time="0"
        new_sum_time="0"
    fi

    # Check if files changed or tidy had output
    if [ $tidy_exit -ne 0 ] || [ -n "${tidy_output}" ] ||
       [ "${orig_mod_time}" != "${new_mod_time}" ] ||
       [ "${orig_sum_time}" != "${new_sum_time}" ]; then
        echo "Please run 'go mod tidy -v'"
        [ -n "${tidy_output}" ] && echo "${tidy_output}"
        if [ -n "${tidy_output}" ]; then
            errors=$((errors + $(echo "${tidy_output}" | wc -l)))
        else
            errors=$((errors + 1))
        fi
    fi

    # Restore original files
    mv -f "$tmp_dir/go.mod" "$tmp_dir/go.sum" ./
else
    echo "Warning: go.mod/go.sum not found or go not available, skipping mod tidy check"
fi

echo
echo '---------------------- GoVet verify ----------------------'
echo
if command -v go >/dev/null 2>&1; then
    vet_output=$(go vet ./... 2>&1)
    vet_exit=$?
    if [ $vet_exit -ne 0 ] || [ -n "${vet_output}" ]; then
        echo "Please fix the issues:"
        echo "${vet_output}"
        # Count lines, handling empty output
        if [ -n "${vet_output}" ]; then
            vet_lines=$(echo "${vet_output}" | wc -l)
            errors=$((errors + (vet_lines + 1) / 2))
        else
            errors=$((errors + 1))
        fi
    fi
else
    echo "Warning: go not found, skipping vet check"
fi

echo
echo "---------------------- Summary ----------------------"
echo "Total errors found: ${errors}"
echo

exit ${errors}
