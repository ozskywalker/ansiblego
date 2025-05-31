# build.ps1 - PowerShell version of build.sh
# Pack and creates multibinary executables

param(
    [string]$PKG_SUFFIX = "gz"  # Can be 'raw', 'upx', 'xz', or 'gz'
)

$ErrorActionPreference = "Stop"

# TODO: Using gz for now due to upx isn't working on macos
# as expected and seems related to the code signature issues.
# GZ is used due to it's speed, compatibility and quite small binary size.

$name = "ansiblego"
$suffixes = @("linux-amd64", "linux-arm64", "windows-amd64", "darwin-amd64", "darwin-arm64")

Write-Host "=== Building $name with package suffix: $PKG_SUFFIX ===" -ForegroundColor Cyan
Write-Host

# Running static code checks
Write-Host "Running static code checks..." -ForegroundColor Yellow
if (Test-Path "./check.ps1") {
    & ./check.ps1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Check script failed with exit code $LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }
} elseif (Test-Path "./check.sh") {
    Write-Host "Warning: check.ps1 not found, trying check.sh..." -ForegroundColor Yellow
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        bash ./check.sh
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Check script failed with exit code $LASTEXITCODE" -ForegroundColor Red
            exit $LASTEXITCODE
        }
    } else {
        Write-Host "Warning: bash not available, skipping check.sh" -ForegroundColor Yellow
    }
} else {
    Write-Host "Warning: No check script found" -ForegroundColor Yellow
}

# Disabling cgo in order to not link with libc and utilize static linkage binaries
# which will help to not relay on glibc on linux and be truely independent from OS
$env:CGO_ENABLED = "0"

# Build all binaries in parallel
Write-Host "`nBuilding binaries..." -ForegroundColor Green
$jobs = @()

foreach ($suffix in $suffixes) {
    Write-Host "--> Build binary for $suffix" -ForegroundColor Cyan

    $parts = $suffix -split '-'
    $goos = $parts[0]
    $goarch = $parts[1]

    $job = Start-Job -ScriptBlock {
        param($goos, $goarch, $name, $suffix, $workingDir)

        # Set the working directory in the job
        Set-Location $workingDir

        $env:GOOS = $goos
        $env:GOARCH = $goarch
        $env:CGO_ENABLED = "0"

        # Utilizing a number of optimizations to reduce the exec binary size
        & go build -ldflags="-s -w" -gcflags=all="-l -B" -a -o "$name.raw.$suffix" "./cmd/$name"

        if ($LASTEXITCODE -ne 0) {
            throw "Build failed for $suffix"
        }
    } -ArgumentList $goos, $goarch, $name, $suffix, $PWD.Path

    $jobs += $job
}

# Wait for all builds to complete
Write-Host "`nWaiting for builds to complete..." -ForegroundColor Yellow
$failed = $false
foreach ($job in $jobs) {
    $result = Receive-Job -Job $job -Wait
    if ($job.State -eq "Failed") {
        Write-Host "Build job failed: $($job.ChildJobs[0].JobStateInfo.Reason)" -ForegroundColor Red
        $failed = $true
    }
    Remove-Job -Job $job
}

if ($failed) {
    Write-Host "One or more builds failed" -ForegroundColor Red
    exit 1
}

# Pack the executables if not raw
if ($PKG_SUFFIX -ne "raw") {
    Write-Host "`nPacking binaries..." -ForegroundColor Green
    $packJobs = @()

    foreach ($suffix in $suffixes) {
        $binName = "$name.raw.$suffix"
        $outName = "$name.$PKG_SUFFIX.$suffix"

        # Check if binary exists
        if (-not (Test-Path $binName)) {
            Write-Host "Error: Source binary $binName not found" -ForegroundColor Red
            exit 1
        }

        # Run the packers only if the results are older than raw binary
        if ((-not (Test-Path $outName)) -or ((Get-Item $binName).LastWriteTime -gt (Get-Item $outName -ErrorAction SilentlyContinue).LastWriteTime)) {
            switch ($PKG_SUFFIX) {
                "upx" {
                    if (Get-Command upx -ErrorAction SilentlyContinue) {
                        Write-Host "--> UPX pack binary for $suffix" -ForegroundColor Cyan
                        $job = Start-Job -ScriptBlock {
                            param($outName, $binName, $workingDir)
                            Set-Location $workingDir
                            & upx --brute -q -9 -o $outName $binName
                        } -ArgumentList $outName, $binName, $PWD.Path
                        $packJobs += $job
                    } else {
                        Write-Host "Warning: upx not found, copying raw binary" -ForegroundColor Yellow
                        Copy-Item $binName $outName
                    }
                }
                "xz" {
                    if (Get-Command xz -ErrorAction SilentlyContinue) {
                        Write-Host "--> XZ pack binary for $suffix" -ForegroundColor Cyan
                        $job = Start-Job -ScriptBlock {
                            param($outName, $binName, $workingDir)
                            Set-Location $workingDir
                            & xz -z -9e -T0 -c $binName > $outName
                        } -ArgumentList $outName, $binName, $PWD.Path
                        $packJobs += $job
                    } else {
                        Write-Host "Warning: xz not found, using gzip instead" -ForegroundColor Yellow
                        # PowerShell has built-in gzip support
                        $content = [System.IO.File]::ReadAllBytes($binName)
                        $compressed = [System.IO.MemoryStream]::new()
                        $gzipStream = [System.IO.Compression.GzipStream]::new($compressed, [System.IO.Compression.CompressionLevel]::Optimal)
                        $gzipStream.Write($content, 0, $content.Length)
                        $gzipStream.Close()
                        [System.IO.File]::WriteAllBytes($outName, $compressed.ToArray())
                    }
                }
                "gz" {
                    Write-Host "--> Gzip pack binary for $suffix" -ForegroundColor Cyan
                    # PowerShell has built-in gzip support
                    $content = [System.IO.File]::ReadAllBytes($binName)
                    $compressed = [System.IO.MemoryStream]::new()
                    $gzipStream = [System.IO.Compression.GzipStream]::new($compressed, [System.IO.Compression.CompressionLevel]::Optimal)
                    $gzipStream.Write($content, 0, $content.Length)
                    $gzipStream.Close()
                    [System.IO.File]::WriteAllBytes($outName, $compressed.ToArray())
                }
            }
        }
    }

    # Wait for pack jobs
    foreach ($job in $packJobs) {
        Receive-Job -Job $job -Wait | Out-Null
        Remove-Job -Job $job
    }
}

# Combine the archs together
Write-Host "`nCombining binaries..." -ForegroundColor Green
foreach ($outSuffix in $suffixes) {
    Write-Host "--> Combining binaries for $outSuffix" -ForegroundColor Cyan

    $outBin = "$name.out.$outSuffix"
    if ($outSuffix -like "*windows*") {
        $outBin += ".exe"
    }

    # Select the appropriate binary based on package type
    if ($PKG_SUFFIX -eq "raw" -or $PKG_SUFFIX -eq "upx") {
        Copy-Item "$name.$PKG_SUFFIX.$outSuffix" $outBin
    } else {
        # We can't use xz/gz binary as the host one
        Copy-Item "$name.raw.$outSuffix" $outBin
    }

    # Combine with the rest of the archs
    foreach ($packSuffix in $suffixes) {
        if ($outSuffix -eq $packSuffix) { continue }

        Write-Host "-->   + $packSuffix"
        $packBin = "$name.$PKG_SUFFIX.$packSuffix"

        if (-not (Test-Path $packBin)) {
            Write-Host "Error: Packed binary $packBin not found" -ForegroundColor Red
            exit 1
        }

        # Append embedded binary marker and content
        Add-Content -Path $outBin -Value "" -Encoding UTF8
        Add-Content -Path $outBin -Value "--- EMBEDDED_BINARY $packSuffix $PKG_SUFFIX ---" -NoNewline -Encoding UTF8
        # Append binary content properly
        $binaryContent = [System.IO.File]::ReadAllBytes($packBin)
        [System.IO.File]::AppendAllText($outBin, [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
        $stream = [System.IO.File]::OpenWrite($outBin)
        $stream.Seek(0, [System.IO.SeekOrigin]::End)
        $stream.Write($binaryContent, 0, $binaryContent.Length)
        $stream.Close()
    }
}

# Combine the sh bundle
Write-Host "`n--> Combining binaries to shell bundle" -ForegroundColor Cyan
$outBin = "$name.out.sh.bundle"

if (-not (Test-Path "unix_bundle.sh.head")) {
    Write-Host "Error: unix_bundle.sh.head not found" -ForegroundColor Red
    exit 1
}

Copy-Item "unix_bundle.sh.head" $outBin
# Make it executable (on Unix-like systems)
if ($PSVersionTable.Platform -ne "Win32NT") {
    chmod +x $outBin
}

foreach ($packSuffix in $suffixes) {
    Write-Host "-->   + $packSuffix"
    $packBin = "$name.$PKG_SUFFIX.$packSuffix"

    if (-not (Test-Path $packBin)) {
        Write-Host "Error: Packed binary $packBin not found" -ForegroundColor Red
        exit 1
    }

    # Append embedded binary marker and content
    Add-Content -Path $outBin -Value "" -Encoding UTF8
    Add-Content -Path $outBin -Value "--- EMBEDDED_BINARY $packSuffix $PKG_SUFFIX ---" -NoNewline -Encoding UTF8
    # Append binary content properly
    $binaryContent = [System.IO.File]::ReadAllBytes($packBin)
    [System.IO.File]::AppendAllText($outBin, [System.Environment]::NewLine, [System.Text.Encoding]::UTF8)
    $stream = [System.IO.File]::OpenWrite($outBin)
    $stream.Seek(0, [System.IO.SeekOrigin]::End)
    $stream.Write($binaryContent, 0, $binaryContent.Length)
    $stream.Close()
}

Write-Host "`nBuild completed successfully!" -ForegroundColor Green
Write-Host "Output files:" -ForegroundColor Yellow
Get-ChildItem "$name.out.*" | ForEach-Object {
    Write-Host "  - $($_.Name) ($([math]::Round($_.Length / 1MB, 2)) MB)" -ForegroundColor Cyan
}
