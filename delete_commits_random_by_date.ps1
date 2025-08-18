Param(
    [Parameter(Mandatory = $true)][datetime]$StartDate,
    [Parameter(Mandatory = $true)][datetime]$EndDate,
    [double]$Probability = 0.2,
    [switch]$Apply = $false,
    [switch]$UseAuthorDate = $false
)

# Basic validation
if ($StartDate.Date -gt $EndDate.Date) { throw "StartDate must be <= EndDate" }
if ($Probability -lt 0 -or $Probability -gt 1) { throw "Probability must be between 0.0 and 1.0" }

# Ensure we are inside a git repo
$insideRepo = $false
try { $null = git rev-parse --is-inside-work-tree 2>$null; if ($LASTEXITCODE -eq 0) { $insideRepo = $true } } catch {}
if (-not $insideRepo) { throw "This script must be run inside a Git repository." }

$gitDir = git rev-parse --git-dir 2>$null
if (-not $gitDir) { throw "Unable to locate .git directory." }

# Choose which date to use for selection: committer (default) or author
$dateField = if ($UseAuthorDate) { "%ad" } else { "%cd" }

# Build list of days to consider
$selectedDays = New-Object System.Collections.Generic.List[datetime]
$allDays = New-Object System.Collections.Generic.List[datetime]

$cursor = $StartDate.Date
while ($cursor -le $EndDate.Date) {
    $allDays.Add($cursor)
    $r = Get-Random -Minimum 0.0 -Maximum 1.0
    if ($r -lt $Probability) { $selectedDays.Add($cursor) }
    $cursor = $cursor.AddDays(1)
}

# Collect commit SHAs to drop for the selected days
$dropShaSet = New-Object System.Collections.Generic.HashSet[string]
$totalMarked = 0

foreach ($day in $selectedDays) {
    $dayStart = (Get-Date -Date $day -Hour 0 -Minute 0 -Second 0 -Millisecond 0).ToString('yyyy-MM-ddTHH:mm:ssK')
    $dayEnd = (Get-Date -Date $day.AddDays(1) -Hour 0 -Minute 0 -Second 0 -Millisecond 0).ToString('yyyy-MM-ddTHH:mm:ssK')

    # Use committer date by default; author date if -UseAuthorDate set
    # git rev-list --since/--until are based on committer date; to filter by author dates
    # we query and post-filter by the chosen field.
    $shas = git rev-list --all --since=$dayStart --until=$dayEnd 2>$null
    if ($UseAuthorDate) {
        # Post-filter by author date falling within the day
        foreach ($sha in $shas) {
            if (-not $sha) { continue }
            $authorDate = git show -s --date=iso-strict --pretty=format:%ad $sha 2>$null
            if (-not $authorDate) { continue }
            $dt = [datetime]::Parse($authorDate)
            if ($dt.Date -eq $day.Date) {
                if ($dropShaSet.Add($sha)) { $totalMarked++ }
            }
        }
    } else {
        foreach ($sha in $shas) { if ($sha -and $dropShaSet.Add($sha)) { $totalMarked++ } }
    }
}

Write-Host ("Days in range: {0}" -f $allDays.Count)
Write-Host ("Selected days (≈{0:p0}): {1}" -f $Probability, $selectedDays.Count)
if ($selectedDays.Count -gt 0) {
    $selectedDayStrings = ($selectedDays | ForEach-Object { $_.ToString('yyyy-MM-dd') } | Sort-Object)
    Write-Host ("Selected day list: {0}" -f ($selectedDayStrings -join ', '))
}
Write-Host ("Commits marked to delete: {0}" -f $totalMarked)

if (-not $Apply) {
    Write-Host "Dry-run only. Re-run with -Apply to rewrite history and delete the marked commits."
    return
}

if ($totalMarked -eq 0) {
    Write-Host "No commits to delete for the randomly selected days. Nothing to do."
    return
}

# Confirm we are not in the middle of a rebase/merge
$status = git status --porcelain 2>$null
$stashed = $false
if ($status -ne $null -and $status.Trim().Length -ne 0) {
    Write-Warning "Working tree is not clean. Stashing changes temporarily for rewrite."
    git stash push --include-untracked -m 'pre-rewrite-stash (delete_commits_random_by_date)' | Out-Null
    $stashed = $true
}

# Ensure tree is pristine for filter-branch
git update-index -q --refresh | Out-Null
git reset --hard | Out-Null
git clean -xfd | Out-Null

# Save SHAs to a file under .git
$listPath = Join-Path $gitDir 'drop_commits_by_date.txt'
[System.IO.File]::WriteAllLines($listPath, $dropShaSet)
Write-Host ("Wrote {0} SHAs to {1}" -f $dropShaSet.Count, $listPath)

# Create a small bash script to handle quoting and run filter-branch
# Prepare a clean temporary worktree to avoid dirty-tree checks
$worktreePath = Join-Path $gitDir 'rewrite_wt'
if (Test-Path $worktreePath) { git worktree remove --force $worktreePath 2>$null | Out-Null }
git worktree add --detach $worktreePath HEAD | Out-Null

$rewriteScript = @"
#!/usr/bin/env bash
set -eu
LIST="$(git rev-parse --git-dir)/drop_commits_by_date.txt"
WORKTREE="$(git rev-parse --git-dir)/rewrite_wt"
export FILTER_BRANCH_SQUELCH_WARNING=1
export GIT_PAGER=cat
cd "$WORKTREE"
git filter-branch --tag-name-filter cat --commit-filter '
  if grep -i -F -q "$GIT_COMMIT" "$LIST"; then
    skip_commit "$@"
  else
    git commit-tree "$@"
  fi
' -f -- --all
"@

$rewritePath = Join-Path $gitDir 'rewrite_drop_commits.sh'
# Normalize to LF endings to avoid bash issues on Windows
$lfScript = $rewriteScript -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($rewritePath, $lfScript, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Rewriting history to drop selected commits..."
try {
    $env:GIT_PAGER = 'cat'
    bash -lc 'bash "$(git rev-parse --git-dir)/rewrite_drop_commits.sh"' | Out-Null
} catch {
    throw "Failed to run git filter-branch. Ensure Git Bash is installed and available in PATH. Error: $($_.Exception.Message)"
}

# Clean up temporary worktree
try { git worktree remove --force $worktreePath 2>$null | Out-Null } catch {}

if ($stashed) {
    try {
        git stash pop | Out-Null
        Write-Host "Restored previously stashed changes."
    } catch {
        Write-Warning "Could not auto-apply stashed changes; please resolve manually with 'git stash list' and 'git stash pop'."
    }
}

Write-Host "Done. This repo's history has been rewritten. To update GitHub, force-push your branches (e.g. 'git push --force-with-lease origin main')."


