# Tests of get-kira.ps1 run without a clone: it fetches a scratch copy of the repository.
# Runs with Windows PowerShell 5.1 and PowerShell 7: scripts/test.ps1
# Requirements are those of the specification in issue #86.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$shell = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('kirakit-test.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failures = 0

function Test-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host "ok   $Name"
    } else {
        Write-Host "FAIL $Name"
        if ($Detail) { Write-Host $Detail }
        $script:failures++
    }
}

# Runs a git command quietly, and stops on failure.
function Invoke-Git {
    $ErrorActionPreference = 'Continue'
    $out = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $args failed:`n$out" }
}

# The scratch remote: the working tree, committed on main, with an annotated tag (as release
# tags are), then one more commit on main after the tag.
$remote = Join-Path $tmp 'remote'
New-Item -ItemType Directory -Path $remote | Out-Null
Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.Name -ne '.git' } |
    Copy-Item -Destination $remote -Recurse -Force
$who = @('-c', 'user.name=test', '-c', 'user.email=test@example.com')
Invoke-Git -C $remote init -q -b main
Invoke-Git -C $remote -c core.safecrlf=false -c core.autocrlf=false add -A
Invoke-Git -C $remote @who -c commit.gpgsign=false commit -q -m initial
Invoke-Git -C $remote @who -c tag.gpgsign=false tag -a -m v0.11.0 v0.11.0
$pullSkill = Join-Path (Join-Path (Join-Path (Join-Path $remote 'claude') 'skills') 'pull') 'SKILL.md'
Add-Content -LiteralPath $pullSkill -Value 'after the tag'
Invoke-Git -C $remote @who -c commit.gpgsign=false commit -q -a -m 'after the tag'
# A file:// URL, so that the fetch is shallow as it is from GitHub.
$remoteUrl = 'file://' + $(if ($remote.StartsWith('/')) { '' } else { '/' }) + $remote.Replace('\', '/')

# The installer alone, outside any clone, as when it is downloaded.
$alone = Join-Path $tmp 'alone'
New-Item -ItemType Directory -Path $alone | Out-Null
$installer = Join-Path $alone 'get-kira.ps1'
Copy-Item -LiteralPath (Join-Path $root 'get-kira.ps1') -Destination $installer

# Runs the installer in a new process with KIRAKIT_REF set to $Ref and the locale set to
# $Locale, and returns its exit code and its output in order: each line of stdout as text,
# each line of stderr as an error record.
function Invoke-Installer([string]$ConfigDir, [string]$Ref, [string]$Locale, [string[]]$Arguments) {
    $saved = @{}
    $vars = @{ CLAUDE_CONFIG_DIR = $ConfigDir; KIRAKIT_REPO = $remoteUrl; KIRAKIT_REF = $Ref; LANG = $Locale; LC_ALL = $Locale }
    foreach ($name in $vars.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $vars[$name])
    }
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $shell -NoProfile -ExecutionPolicy Bypass -File $installer @Arguments `
                -Name Alex -Gender female -Language auto -NoCoAuthor 2>&1)
        return @{ Status = $LASTEXITCODE; Lines = $lines }
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}

# Lines that are not kirakit's own from "kirakit: fetching" (the scratch remote) to
# "kirakit: source", and any line written to stderr: git writes only there. Returns $null
# when "fetching" or "source" is missing.
function Get-ForeignLine($Lines) {
    $fetching = $false
    $source = $false
    $foreign = @()
    foreach ($line in $Lines) {
        $text = "$line"
        if ($line -is [Management.Automation.ErrorRecord]) { $foreign += "stderr: $text"; continue }
        if ($text -like "kirakit: fetching $remoteUrl *") { $fetching = $true }
        if ($fetching -and -not $source -and $text -notlike 'kirakit:*') { $foreign += $text }
        if ($fetching -and $text -like 'kirakit: source: *') { $source = $true }
    }
    if (-not ($fetching -and $source)) { return $null }
    return , $foreign
}

function Test-OnlyKirakit([string]$Name, $Run) {
    $foreign = Get-ForeignLine $Run.Lines
    $ok = $Run.Status -eq 0 -and $null -ne $foreign -and $foreign.Count -eq 0
    Test-Check $Name $ok ("status $($Run.Status):`n" + (($Run.Lines | ForEach-Object { "$_" }) -join "`n"))
}

# R1, R2: only kirakit's lines for an annotated tag and for a branch, in French when git
# has the translation.
$run = Invoke-Installer (Join-Path $tmp 'quiet') 'v0.11.0' 'fr_CA.UTF-8' @('-DryRun')
Test-OnlyKirakit 'fetch: only kirakit lines for an annotated tag (#86 R1, R5)' $run
$run = Invoke-Installer (Join-Path $tmp 'quiet') 'main' 'fr_CA.UTF-8' @('-DryRun')
Test-OnlyKirakit 'fetch: only kirakit lines for a branch (#86 R2, R5)' $run

# R4: the installed source is the commit the requested ref points to.
function Get-InstalledPullSkill([string]$ConfigDir) {
    $path = Join-Path (Join-Path (Join-Path $ConfigDir 'skills') 'pull') 'SKILL.md'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw
}
$atTag = Join-Path $tmp 'at-tag'
$run = Invoke-Installer $atTag 'v0.11.0' 'C' @()
$skill = Get-InstalledPullSkill $atTag
Test-Check 'fetch: a tag installs the commit it points to (#86 R4, R5)' `
    ($run.Status -eq 0 -and $null -ne $skill -and -not $skill.Contains('after the tag')) `
    (($run.Lines | ForEach-Object { "$_" }) -join "`n")
$atMain = Join-Path $tmp 'at-main'
$run = Invoke-Installer $atMain 'main' 'C' @()
$skill = Get-InstalledPullSkill $atMain
Test-Check 'fetch: a branch installs its last commit (#86 R4, R5)' `
    ($run.Status -eq 0 -and $null -ne $skill -and $skill.Contains('after the tag')) `
    (($run.Lines | ForEach-Object { "$_" }) -join "`n")

# R3: an unknown ref fails, with git's error and kirakit's, and installs nothing.
$unknown = Join-Path $tmp 'unknown'
$run = Invoke-Installer $unknown 'no-such-ref' 'C' @()
$output = ($run.Lines | ForEach-Object { "$_" }) -join "`n"
Test-Check 'fetch: an unknown ref fails (#86 R3, R5)' ($run.Status -ne 0) $output
Test-Check "fetch: an unknown ref shows git's error (#86 R3, R5)" `
    $output.Contains("couldn't find remote ref no-such-ref") $output
Test-Check 'fetch: an unknown ref shows could not fetch (#86 R3, R5)' `
    $output.Contains("could not fetch $remoteUrl") $output
Test-Check 'fetch: an unknown ref installs nothing (#86 R3, R5)' (-not (Test-Path -LiteralPath $unknown))

# #122 R1: completing approved pull requests is off by default, saved by its option, kept by
# a later run without it, and turned off by its no option.
function Test-ProfileLine([string]$ConfigDir, [string]$Line) {
    $path = Join-Path $ConfigDir '.kirakit-profile'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    return @(Get-Content -LiteralPath $path) -ccontains $Line
}
$complete = Join-Path $tmp 'complete'
$steps = @(
    @{ Name = 'off by default'; Arguments = @(); Expected = 'complete_approved_prs=no' },
    @{ Name = 'turned on and saved by -CompleteApprovedPrs'; Arguments = @('-CompleteApprovedPrs'); Expected = 'complete_approved_prs=yes' },
    @{ Name = 'kept by a later run without the option'; Arguments = @(); Expected = 'complete_approved_prs=yes' },
    @{ Name = 'turned off by -NoCompleteApprovedPrs'; Arguments = @('-NoCompleteApprovedPrs'); Expected = 'complete_approved_prs=no' }
)
foreach ($step in $steps) {
    $run = Invoke-Installer $complete 'main' 'C' (@('-Copy', '-Assistant', 'Kira <kira@example.com>', '-Coder', 'Cleo <cleo@example.com>') + $step.Arguments)
    Test-Check "complete: $($step.Name) (#122 R1)" ($run.Status -eq 0 -and (Test-ProfileLine $complete $step.Expected)) `
        (($run.Lines | ForEach-Object { "$_" }) -join "`n")
    # #122 R3-R10 with the setting on and a coder; R2 with it off.
    $team = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $complete 'rules') 'team.md')
    $rules = $team.Contains('`review:lead-only`') -and $team.Contains('and says which condition failed') -and
        $team.Contains('itself always waits for the user''s own approval.') -and
        $team.Contains('no specification, the same comment goes on the task.') -and
        $team.Contains('once rebased and approved again by the assistant, the conditions above are')
    if ($step.Expected -eq 'complete_approved_prs=yes') {
        Test-Check "complete: $($step.Name), completion rules installed (#122 R3, R4, R5, R6, R7, R8, R9, R10)" $rules
    } else {
        Test-Check "complete: $($step.Name), no completion rule (#122 R2)" `
            (-not $rules -and -not $team.Contains('review:lead-only'))
    }
}

# #122 R2: with the setting on and no coder, the installed files are those without it.
$nocoderOn = Join-Path $tmp 'complete-nocoder-on'
$nocoderOff = Join-Path $tmp 'complete-nocoder-off'
$runOn = Invoke-Installer $nocoderOn 'main' 'C' @('-Copy', '-Assistant', 'Kira <kira@example.com>', '-CompleteApprovedPrs')
$runOff = Invoke-Installer $nocoderOff 'main' 'C' @('-Copy', '-Assistant', 'Kira <kira@example.com>')
$same = $runOn.Status -eq 0 -and $runOff.Status -eq 0
foreach ($path in @('CLAUDE.md', (Join-Path 'rules' 'git.md'))) {
    $on = Get-Content -Raw -LiteralPath (Join-Path $nocoderOn $path)
    $off = Get-Content -Raw -LiteralPath (Join-Path $nocoderOff $path)
    if ($on -cne $off) { $same = $false }
}
Test-Check 'complete: on without a coder, the files without the setting (#122 R2)' $same

# #185 R4, R5: starting verified specifications is off by default, saved by its option, kept
# by a later run without it, and turned off by its no option; it installs review-spec only
# when on, with an analyst and a coder.
$verified = Join-Path $tmp 'verified'
$steps = @(
    @{ Name = 'off by default'; Arguments = @(); Expected = 'start_verified_specs=no' },
    @{ Name = 'turned on and saved by -StartVerifiedSpecs'; Arguments = @('-StartVerifiedSpecs'); Expected = 'start_verified_specs=yes' },
    @{ Name = 'kept by a later run without the option'; Arguments = @(); Expected = 'start_verified_specs=yes' },
    @{ Name = 'turned off by -NoStartVerifiedSpecs'; Arguments = @('-NoStartVerifiedSpecs'); Expected = 'start_verified_specs=no' }
)
foreach ($step in $steps) {
    $run = Invoke-Installer $verified 'main' 'C' (@('-Copy', '-Assistant', 'Kira <kira@example.com>', '-Analyst', '-Coder', 'Cleo <cleo@example.com>') + $step.Arguments)
    Test-Check "verified: $($step.Name) (#185 R4)" ($run.Status -eq 0 -and (Test-ProfileLine $verified $step.Expected)) `
        (($run.Lines | ForEach-Object { "$_" }) -join "`n")
    $reviewSpec = Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $verified 'skills') 'review-spec') 'SKILL.md')
    if ($step.Expected -eq 'start_verified_specs=yes') {
        Test-Check "verified: $($step.Name), review-spec installed (#185 R4, R10)" $reviewSpec
    } else {
        Test-Check "verified: $($step.Name), no review-spec (#185 R5)" (-not $reviewSpec)
    }
}

# #185 R4: with the setting on and no coder, the installed files are those without it.
$verifiedOn = Join-Path $tmp 'verified-nocoder-on'
$verifiedOff = Join-Path $tmp 'verified-nocoder-off'
$runOn = Invoke-Installer $verifiedOn 'main' 'C' @('-Copy', '-Assistant', 'Kira <kira@example.com>', '-Analyst', '-StartVerifiedSpecs')
$runOff = Invoke-Installer $verifiedOff 'main' 'C' @('-Copy', '-Assistant', 'Kira <kira@example.com>', '-Analyst')
$same = $runOn.Status -eq 0 -and $runOff.Status -eq 0
foreach ($path in @('CLAUDE.md', (Join-Path 'rules' 'team.md'), (Join-Path (Join-Path 'skills' 'spec') 'SKILL.md'))) {
    $on = Get-Content -Raw -LiteralPath (Join-Path $verifiedOn $path)
    $off = Get-Content -Raw -LiteralPath (Join-Path $verifiedOff $path)
    if ($on -cne $off) { $same = $false }
}
Test-Check 'verified: on without a coder, the files without the setting (#185 R4)' $same

# #120: a command per team member, the same as scripts/build.sh builds it.
function Get-RunText($Run) { return (($Run.Lines | ForEach-Object { "$_" }) -join "`n") }
function Get-MemberCommand([string]$Member, [string]$Title, [string]$Model) {
    return ((@('---', "name: $Member",
                "description: Talk to $Title directly: she handles your request in her own persona and answers you.",
                "model: $Model", 'context: fork', "agent: $Member", 'disable-model-invocation: true', '---', '',
                "The user addresses you directly with the ``/$Member`` command, from the lead's conversation.",
                'Their request:', '', '$ARGUMENTS', '',
                'Handle it as one exchange, in your own persona and under your own rules, and end with your',
                'answer to the user, written for the user, your questions included.', '',
                'When the request above is empty, answer in one line asking what the user wants from you.') -join "`n") + "`n")
}
function Get-Installed([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [IO.File]::ReadAllText($Path)
}
$members = Join-Path $tmp 'members'
$run = Invoke-Installer $members 'main' 'C' @('-Copy', '-Analyst', '-Coder', 'Cleo <cleo@example.com>')
$manifestText = Get-Installed (Join-Path $members '.kirakit-manifest')
foreach ($member in @(@{ Name = 'iris'; Title = 'Iris'; Model = 'opus' }, @{ Name = 'cleo'; Title = 'Cleo'; Model = 'sonnet' })) {
    $dir = Join-Path (Join-Path $members 'skills') $member.Name
    $text = Get-Installed (Join-Path $dir 'SKILL.md')
    Test-Check "commands: /$($member.Name) built and installed (#120 R1, R10)" ($run.Status -eq 0 -and $null -ne $text) (Get-RunText $run)
    Test-Check "commands: /$($member.Name) front matter and body, as build.sh writes them (#120 R1, R4, R5, R8)" `
        ($text -ceq (Get-MemberCommand $member.Name $member.Title $member.Model)) "$text"
    Test-Check "commands: /$($member.Name) recorded (#120 R10)" ($null -ne $manifestText -and $manifestText.Contains($dir))
}
$commandCount = @(Get-ChildItem -LiteralPath (Join-Path $members 'skills') -Recurse -Filter 'SKILL.md' |
        Where-Object { (Get-Content -LiteralPath $_.FullName) -match '^agent: ' }).Count
Test-Check 'commands: none for the lead (#120 R3)' ($commandCount -eq 2 -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $members 'skills') 'kira')))
$irisCommand = Join-Path (Join-Path $members 'skills') 'iris'
$run = Invoke-Installer $members 'main' 'C' @('-Copy', '-NoAnalyst')
Test-Check 'commands: /iris removed without an analyst (#120 R2, R10)' ($run.Status -eq 0 -and -not (Test-Path -LiteralPath $irisCommand)) (Get-RunText $run)
Test-Check 'commands: /iris no longer recorded (#120 R10)' (-not (Get-Installed (Join-Path $members '.kirakit-manifest')).Contains($irisCommand))
$run = Invoke-Installer $members 'main' 'C' @('-Copy', '-Analyst')
Test-Check 'commands: /iris back on reinstall (#120 R10)' ($run.Status -eq 0 -and (Test-Path -LiteralPath (Join-Path $irisCommand 'SKILL.md'))) (Get-RunText $run)
$run = Invoke-Installer $members 'main' 'C' @('-Uninstall')
Test-Check 'commands: uninstall removes them (#120 R10)' ($run.Status -eq 0 -and -not (Test-Path -LiteralPath $irisCommand) -and
    -not (Test-Path -LiteralPath (Join-Path (Join-Path $members 'skills') 'cleo'))) (Get-RunText $run)
$none = Join-Path $tmp 'members-none'
$run = Invoke-Installer $none 'main' 'C' @('-Copy', '-NoAnalyst')
Test-Check 'commands: none without an analyst or a coder (#120 R2)' ($run.Status -eq 0 -and
    -not (Test-Path -LiteralPath (Join-Path (Join-Path $none 'skills') 'iris')) -and
    -not (Test-Path -LiteralPath (Join-Path (Join-Path $none 'skills') 'cleo'))) (Get-RunText $run)

# A new member gets her command, and a member named like a skill stops the build: each on a
# branch of the scratch remote.
$nova = @('---', 'name: Nova', 'description: Nova, a new member', 'delegate: Use Nova.', 'model: haiku', '---', '', 'Body.')
Invoke-Git -C $remote checkout -q -b new-member main
[IO.File]::WriteAllText((Join-Path (Join-Path $remote 'team') 'nova.md'), (($nova -join "`n") + "`n"))
Invoke-Git -C $remote add -A
Invoke-Git -C $remote @who -c commit.gpgsign=false commit -q -m 'new member'
Invoke-Git -C $remote checkout -q -b member-clash main
[IO.File]::WriteAllText((Join-Path (Join-Path $remote 'team') 'test.md'), (($nova -join "`n") + "`n"))
Invoke-Git -C $remote add -A
Invoke-Git -C $remote @who -c commit.gpgsign=false commit -q -m 'member clash'
Invoke-Git -C $remote checkout -q main
$newMember = Join-Path $tmp 'members-new'
$run = Invoke-Installer $newMember 'new-member' 'C' @('-Copy')
Test-Check 'commands: a new member gets hers (#120 R2)' ($run.Status -eq 0 -and
    (Get-Installed (Join-Path (Join-Path (Join-Path $newMember 'skills') 'nova') 'SKILL.md')) -ceq (Get-MemberCommand 'nova' 'Nova' 'haiku')) (Get-RunText $run)
$run = Invoke-Installer (Join-Path $tmp 'members-clash') 'member-clash' 'C' @('-Copy')
Test-Check 'commands: a clash with a skill fails, naming the member (#120 R9)' ($run.Status -ne 0 -and
    (Get-RunText $run).Contains('team member test has the same name as the skill')) (Get-RunText $run)

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($failures) {
    Write-Host "$failures check(s) failed"
    exit 1
}
Write-Host 'all checks passed'
# The last run failed on purpose: do not leave its exit code as the script's.
exit 0
