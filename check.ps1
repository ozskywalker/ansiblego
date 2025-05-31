# check.ps1 - PowerShell version of check.sh
# Script to simplify the style check process

$errors = 0

Write-Host ""
Write-Host "---------------------- Custom Checks ----------------------" -ForegroundColor Yellow
Write-Host ""

# Get all files tracked by git
$gitFiles = git ls-files
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Failed to get git files" -ForegroundColor Red
    exit 1
}

# Get the current directory to ensure proper path resolution
$currentDir = Get-Location

foreach ($f in $gitFiles) {
    # Ensure we have the full path
    $fullPath = Join-Path $currentDir $f

    # Check if it's a text file
    if (Test-Path $fullPath) {
        # PowerShell doesn't have 'file' command, so we check by extension and content
        $textExtensions = @('.go', '.mod', '.sum', '.sh', '.ps1', '.md', '.txt', '.yml', '.yaml', '.json', '.xml')
        $extension = [System.IO.Path]::GetExtension($f)

        $isTextFile = $false
        if ($extension -in $textExtensions) {
            $isTextFile = $true
        } else {
            # Try to read as text
            try {
                $null = Get-Content $fullPath -ErrorAction Stop
                $isTextFile = $true
            } catch {
                $isTextFile = $false
            }
        }

        if ($isTextFile) {
            # Check if file ends with newline
            try {
                $content = [System.IO.File]::ReadAllBytes($fullPath)
                if ($content.Length -gt 0 -and $content[-1] -ne 10) {  # 10 is newline character
                    Write-Host "Not ends with newline: $f" -ForegroundColor Red
                    $errors++
                }
            } catch {
                Write-Host "Warning: Could not read file: $f" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ""
Write-Host "---------------------- GoFmt verify ----------------------" -ForegroundColor Yellow
Write-Host ""

if (Get-Command gofmt -ErrorAction SilentlyContinue) {
    $reformat = gofmt -l .
    if ($reformat) {
        Write-Host "Please run 'gofmt -w .':" -ForegroundColor Red
        Write-Host $reformat
        $errors += ($reformat | Measure-Object -Line).Lines
    }
} else {
    Write-Host "Warning: gofmt not found, skipping format check" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "---------------------- GoModTidy verify ----------------------" -ForegroundColor Yellow
Write-Host ""

if ((Test-Path "go.mod") -and (Test-Path "go.sum") -and (Get-Command go -ErrorAction SilentlyContinue)) {
    # Create temporary directory
    $tempDir = New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path $_ }

    try {
        # Save original files
        Copy-Item "go.mod" -Destination "$tempDir/go.mod"
        Copy-Item "go.sum" -Destination "$tempDir/go.sum"

        # Get original modification times
        $origModTime = (Get-Item "go.mod").LastWriteTime
        $origSumTime = (Get-Item "go.sum").LastWriteTime

        # Run go mod tidy
        $tidyOutput = go mod tidy -v 2>&1
        $tidyExitCode = $LASTEXITCODE

        # Get new modification times
        $newModTime = (Get-Item "go.mod").LastWriteTime
        $newSumTime = (Get-Item "go.sum").LastWriteTime

        # Check if files changed or tidy had output
        if ($tidyExitCode -ne 0 -or $tidyOutput -or
            $origModTime -ne $newModTime -or
            $origSumTime -ne $newSumTime) {
            Write-Host "Please run 'go mod tidy -v'" -ForegroundColor Red
            if ($tidyOutput) {
                Write-Host $tidyOutput
                $errors += ($tidyOutput | Measure-Object -Line).Lines
            } else {
                $errors++
            }
        }

        # Restore original files
        Move-Item "$tempDir/go.mod" -Destination "." -Force
        Move-Item "$tempDir/go.sum" -Destination "." -Force
    }
    finally {
        # Clean up temp directory
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "Warning: go.mod/go.sum not found or go not available, skipping mod tidy check" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "---------------------- GoVet verify ----------------------" -ForegroundColor Yellow
Write-Host ""

if (Get-Command go -ErrorAction SilentlyContinue) {
    $vetOutput = go vet ./... 2>&1
    $vetExitCode = $LASTEXITCODE

    if ($vetExitCode -ne 0 -or $vetOutput) {
        Write-Host "Please fix the issues:" -ForegroundColor Red
        Write-Host $vetOutput
        if ($vetOutput) {
            $vetLines = ($vetOutput | Measure-Object -Line).Lines
            $errors += [math]::Ceiling($vetLines / 2)
        } else {
            $errors++
        }
    }
} else {
    Write-Host "Warning: go not found, skipping vet check" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "---------------------- Summary ----------------------" -ForegroundColor Yellow
Write-Host "Total errors found: $errors" -ForegroundColor $(if ($errors -gt 0) { "Red" } else { "Green" })
Write-Host ""

exit $errors
