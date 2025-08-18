Param(
    [int]$Year = (Get-Date).Year,
    [int]$Month = 5,
    [int]$MinCommits = 0,
    [int]$MaxCommits = 18,
    [int]$StartDay = 1,
    [int]$EndDay = 0
)

# Validate inputs
if ($MinCommits -lt 0) { throw "MinCommits must be >= 0" }
if ($MaxCommits -lt $MinCommits) { throw "MaxCommits must be >= MinCommits" }
if ($Month -lt 1 -or $Month -gt 12) { throw "Month must be between 1 and 12" }

$insideRepo = $false
try {
    $null = git rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) { $insideRepo = $true }
} catch {}
if (-not $insideRepo) { throw "This script must be run inside a Git repository." }

# Ensure local git user is configured
$userName = git config --get user.name 2>$null
if (-not $userName) { git config user.name "Backfill Bot" | Out-Null }
$userEmail = git config --get user.email 2>$null
if (-not $userEmail) { git config user.email "backfill@example.com" | Out-Null }

$daysInMonth = [DateTime]::DaysInMonth($Year, $Month)

# Normalize and validate day range
if ($EndDay -le 0) { $EndDay = $daysInMonth }
if ($StartDay -lt 1 -or $StartDay -gt $daysInMonth) { throw "StartDay must be between 1 and $daysInMonth" }
if ($EndDay -lt $StartDay -or $EndDay -gt $daysInMonth) { throw "EndDay must be between StartDay and $daysInMonth" }

for ($day = $StartDay; $day -le $EndDay; $day++) {
    # Anchor commits around midday local time to avoid DST edge cases
    $baseTime = Get-Date -Year $Year -Month $Month -Day $day -Hour 12 -Minute 0 -Second 0 -Millisecond 0

    # Get random commits count inclusive of Max
    $commitsForDay = Get-Random -Minimum $MinCommits -Maximum ($MaxCommits + 1)

    for ($i = 1; $i -le $commitsForDay; $i++) {
        # Stagger each commit by one minute to ensure unique timestamps
        $commitTime = $baseTime.AddMinutes($i)

        # ISO 8601 with timezone offset (e.g., 2025-05-10T12:34:56+02:00)
        $iso = $commitTime.ToString("yyyy-MM-ddTHH:mm:ssK")

        $env:GIT_AUTHOR_DATE = $iso
        $env:GIT_COMMITTER_DATE = $iso

        git commit --allow-empty -m ("chore: backfill " + $commitTime.ToString('yyyy-MM-dd') + " #" + $i) | Out-Null
    }
}

Write-Host ("Created backfilled commits for {0}/{1} days {2}-{3} with {4}-{5} commits per day." -f $Month, $Year, $StartDay, $EndDay, $MinCommits, $MaxCommits)


