[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$url,

    [string]$sourceBranch = "master",

    # Glob expression of directory names to delete from history (e.g. "*-tmp").
    # Matches on NAMES, not on paths. Wildcards allowed.
    [Parameter()]
    [string]$deleteDirectories,

    # List of file extensions (e.g. "exe", "dll", "jpg") to store in LFS.
    # The files are stored but tracking is not configured (assumption being the user already has a tracking config file to use).
    [Parameter()]
    [string[]]$lfsExtensions = @("dll", "exe", "lib", "zip", "so", "pdf", "docx", "xlsx", "xls", "doc", "jpg", "png", "gif")
)

# Clones a single branch of a repo, marks desired files as LFS-stored (including rewriting history),
# optionally deletes garbage directories from history, and performs Git garbage collections.
# Result is not pushed anywhere, just kept in local repo for your inspection.

# We create two directories in the current directory: temp and result.
# Temp contains the first stages of cleanup, which we do without checking out the repo.
# Then we check out the repo into "result" for final adjustments. Once finished, we delete "temp".

$ErrorActionPreference = "Stop"

function VerifySuccess() {
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Last command exited with code $LASTEXITCODE"
    }
}

function CleanGarbage() {
    Write-Host "Cleaning garbage that is no longer part of the timeline"
    git reflog expire --expire=now --all
    VerifySuccess
    
    git gc --prune=now --aggressive
    VerifySuccess
}

Write-Host "Will make a clean copy from branch $sourceBranch on URL $url"

$tempPath = (Get-Location).Path + "/temp"
$resultPath = (Get-Location).Path + "/result"

if ((Test-Path $tempPath) -or (Test-Path $resultPath)) {
    Write-Error "Current directory must be empty."
    return
}

$bfgPath = Resolve-Path "$PSScriptRoot/bfg.jar"

New-Item -ItemType Directory $tempPath | Out-Null

Write-Host "Cloning branch"
git clone --bare --no-tags --single-branch --branch $sourceBranch $url $tempPath
VerifySuccess

if ($deleteDirectories) {
    Write-Host "Removing unwanted directories"
    java -jar $bfgPath --delete-folders $deleteDirectories --no-blob-protection $tempPath
    VerifySuccess
}

Push-Location $tempPath

# We clean garbage also before LFS rewrite just to avoid rewriting what is going to be garbage cleaned anyway.
CleanGarbage

Pop-Location

if ($lfsExtensions) {
    # This makes a,b,c
    $extensionsPattern = [string]::Join(",", $lfsExtensions)
    # This makes *.{a,b,c}
    $lfsPattern = "*.{$extensionsPattern}"

    # This rewrites history but does not configure tracking for new files yet. We do that later.
    Write-Host "Rewriting history to migrate files to LFS"
    java -jar $bfgPath --convert-to-git-lfs $lfsPattern --no-blob-protection $tempPath
    VerifySuccess
}

Push-Location $tempPath

Write-Host "Cleaning garbage that is no longer part of the timeline"
CleanGarbage

Pop-Location

# Now check out the cleaned repo so we can finish LFS adjustments.

Write-Host "Checking out cleaned repo for final adjustments"
git clone $tempPath $resultPath
VerifySuccess

# Push-Location $resultPath

# if ($lfsExtensions) {
#     Write-Host "Marking files as LFS-tracked"
#     foreach ($extension in $lfsExtensions) {
#         $pattern = "*.$extension"

#         git lfs track $pattern
#         VerifySuccess
#     }

#     git add *
#     VerifySuccess

#     git commit -m 'LFS migration'
#     VerifySuccess
# }

# Pop-Location

# Copy LFS artifacts and checkout to verify that LFS is correctly hooked up.

$lfsPath = "$tempPath/lfs"

if (Test-Path $lfsPath) {
    Push-Location $lfsPath

    Write-Host "Merging LFS artifacts into result repo"
    $targetPath = "$resultPath/.git/lfs"
    [IO.Directory]::CreateDirectory($targetPath) | Out-Null

    # This can emit a "directory already exists" error when "creating" one of the intermediate directories.
    # That's fine - it will still go ahead and copy the files within.
    Copy-Item -Recurse * $targetPath -ErrorAction SilentlyContinue

    Pop-Location
}

Push-Location $resultPath

Write-Host "Checking out LFS artifacts into working directory to validate that nothing went missing"
git lfs checkout
VerifySuccess

# Remove the reference to the temp repo to avoid funny business.
git remote remove origin
VerifySuccess

Pop-Location

Write-Host "Deleting temporary repo"
Remove-Item -Recurse -Force $tempPath

Write-Host "All done!"