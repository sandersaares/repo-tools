[CmdletBinding()]
param(
    # The merged repo is merged as /name in the root of the current repo.
    # This name is also used for internal Git workflow objects (remote, branch, etc).
    [Parameter(Mandatory)]
    [string]$name,

    [Parameter(Mandatory)]
    [string]$url,

    [string]$sourceBranch = "master",
    [string]$targetBranch = "migration"
)

# Merges a repo into this repo, preserving history (including commit IDs).

$ErrorActionPreference = "Stop"

function VerifySuccess() {
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Last command exited with code $LASTEXITCODE"
    }
}

function CleanRepo() {
    # There may be some grabage left over if the workdir was not in pristine state. Clean up!
    
    # Reset any pending changes.
    git reset --hard
    VerifySuccess

    # Delete files that are listed in .gitignore.
    git clean -d -f -x
    VerifySuccess
}

Write-Host "Will import $name from branch $sourceBranch on URL $url"

CleanRepo

git remote add $name $url
VerifySuccess

# This only fetches the LFS objects that are in HEAD. We actually want all of history, so we do separate LFS fetch below.
git fetch --no-tags $name $sourceBranch
VerifySuccess

# Create a branch for the subdirectoryfication.
# We use this branch to move move all /xyz into /$name/xyz
git branch --no-track $name $name/$sourceBranch
VerifySuccess

# This ensures the files do not appear in the new branch.
# For whatever reason, Git does not realize the submodules do not exist in the imported branch.
git submodule deinit --all -f
VerifySuccess

# This will leave submodules hanging in the new directory if you don't remove them with above step!
git checkout $name
VerifySuccess

# This fetches all LFS objects for the history of the merged branch.
# We must do it once we have the branch made, so the referencing works correctly.
git lfs fetch --all $name $name
VerifySuccess

CleanRepo

# Git does not "see" empty directories and therefore does not delete them. Let's do it manually.
Get-ChildItem -Directory -Recurse | Where-Object { (Get-ChildItem $_.FullName).Count -eq 0 } | Select-Object -ExpandProperty FullName | Remove-Item

$items = Get-ChildItem

# Do some directory juggling to avoid conflict if existing $name directory exists.
$mergeDir = New-Item "__merge" -ItemType Directory

$items | Move-Item -Destination $mergeDir
Rename-Item $mergeDir $name

git add *
VerifySuccess

git commit -m "Move imported repo contents to /$name"
VerifySuccess

# Merge to main!

git checkout --no-guess $targetBranch
VerifySuccess

git merge --allow-unrelated-histories --no-ff --commit $name
VerifySuccess

# The branch is no longer necessary - merge is complete.
git branch -d $name
VerifySuccess

# And neither is the remote.
git remote remove $name
VerifySuccess

# Submodule files need to be merged manually, as they go in the root and we may want to do custom paths. Alert if this is the case.
$submodulesPath = "$name/.gitmodules"

if (Test-Path $submodulesPath) {
    Write-Warning "You must manually merge the submodules and delete $name/.gitmodules! <------------- ACTION REQUIRED"
    # We leave submodules deinitialized since a merge is needed anyway.
    # You need to:
    # 1. Add any submodules manually.
    # 2. Delete $name/.gitmodules
    # 3. Stage + commit changes.
    # 4. git submodule update --init
}
else {
    # No new submodules appeared - safe to initialize existing ones.
    git submodule update --init
    VerifySuccess
}

Write-Host "All done"