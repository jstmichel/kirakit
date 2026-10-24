<#
.SYNOPSIS
Install kirakit into the Claude Code configuration directory.

.DESCRIPTION
Windows PowerShell 5+ and PowerShell 7 counterpart of get-kira.sh, with the same profile,
files and options.

From a clone, files are copied on Windows (symbolic links need Developer Mode: pass -Link)
and linked elsewhere. Without a clone, the repository is fetched into a temporary directory
and files are copied.

Output styles, skills, agents and CLAUDE.md are personalized from a profile: how Kira calls
the user, the user's gender, the answer language, the assistant (git identity, signing
key, GitHub account, Co-Authored-By trailers), the analyst and the coder. The installer asks once and saves the answers
in $CLAUDE_CONFIG_DIR\.kirakit-profile for later runs.

Without -Only, styles and claude are installed. The github component copies issue and pull
request templates, workflows and Copilot instructions into a repository's .github directory.

Remote use:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Kodara-me/kirakit/main/get-kira.ps1))) -DryRun

Environment: CLAUDE_CONFIG_DIR (default: ~\.claude), KIRAKIT_REPO and KIRAKIT_REF (repository
and branch or tag fetched without a clone; default: the latest release).

.PARAMETER DryRun
Print what would change, change nothing.
.PARAMETER Name
How Kira calls you.
.PARAMETER Gender
male, female, nonbinary or unspecified.
.PARAMETER Language
Answer language, or auto to follow the conversation.
.PARAMETER Assistant
The assistant's git identity, as "NAME <EMAIL>" (its commits, and its trailer in yours).
.PARAMETER AssistantSigningKey
The assistant's public SSH signing key (empty: it does not commit as itself; with a coder, the coder commits its work).
.PARAMETER AssistantGithub
The assistant's own GitHub account (empty: none).
.PARAMETER CoAuthor
Same as -Assistant, with Co-Authored-By trailers.
.PARAMETER NoCoAuthor
Add no Co-Authored-By trailer to commits.
.PARAMETER Analyst
Add Iris, an analyst for ideas and specifications, to the team.
.PARAMETER NoAnalyst
No analyst: Kira writes ideas and specifications herself.
.PARAMETER AnalystGithub
The analyst's own GitHub account (implies -Analyst; empty: none).
.PARAMETER Coder
The coder's git identity, for Cleo, as "NAME <EMAIL>" (default: none).
.PARAMETER CoderSigningKey
The coder's public SSH signing key (empty: none; the assistant then commits her work).
.PARAMETER CoderGithub
The coder's own GitHub account (empty: none).
.PARAMETER AllowReleases
Let the assistant create releases and push tags without a prompt.
.PARAMETER NoAllowReleases
Releases and tags stay behind a prompt (default).
.PARAMETER CompleteApprovedPrs
With a coder, let the assistant complete the coder's pull requests it approved without the user's review.
.PARAMETER NoCompleteApprovedPrs
Every pull request waits for the user's review (default).
.PARAMETER StartVerifiedSpecs
With an analyst and a coder, let the assistant verify the analyst's specifications and move the verified ones to Ready without the user; only security questions are asked.
.PARAMETER NoStartVerifiedSpecs
Every specification waits in Specified for the user (default).
.PARAMETER DefaultStyle
Output style selected in settings.json (default: kira-cozy).
.PARAMETER Reconfigure
Ask all profile questions again.
.PARAMETER Persona
Install only these personas (default: all).
.PARAMETER Only
Install one component: styles, claude (CLAUDE.md, rules, settings, agents, skills) or github.
launchers is accepted for parity with get-kira.sh, but the launchers are not supported on
Windows: nothing is installed.
.PARAMETER Target
Repository for -Only github (default: the current one).
.PARAMETER Link
Symlink files to the local clone.
.PARAMETER Copy
Copy files.
.PARAMETER Uninstall
Remove what kirakit installed in the configuration directory.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Name,
    [ValidateSet('male', 'female', 'nonbinary', 'unspecified')]
    [string]$Gender,
    [string]$Language,
    [string]$Assistant,
    [string]$AssistantSigningKey,
    [string]$AssistantGithub,
    [string]$CoAuthor,
    [switch]$NoCoAuthor,
    [switch]$Analyst,
    [switch]$NoAnalyst,
    [string]$AnalystGithub,
    [string]$Coder,
    [string]$CoderSigningKey,
    [string]$CoderGithub,
    [switch]$AllowReleases,
    [switch]$NoAllowReleases,
    [switch]$CompleteApprovedPrs,
    [switch]$NoCompleteApprovedPrs,
    [switch]$StartVerifiedSpecs,
    [switch]$NoStartVerifiedSpecs,
    [string]$DefaultStyle,
    [switch]$Reconfigure,
    [string[]]$Persona = @(),
    [ValidateSet('styles', 'claude', 'launchers', 'github')]
    [string]$Only,
    [string]$Target,
    [switch]$Link,
    [switch]$Copy,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Bound = $PSBoundParameters

$Repo = if ($env:KIRAKIT_REPO) { $env:KIRAKIT_REPO } else { 'https://github.com/Kodara-me/kirakit.git' }
# Set to the release tag in the copy attached to each GitHub release, so that it installs its
# own version.
$KiraVersion = ''
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$ClaudeDir = [IO.Path]::GetFullPath($ClaudeDir).TrimEnd('\', '/')

$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Nl = "`n"
$Tab = "`t"
$Sep = [IO.Path]::DirectorySeparatorChar
$ProfilePath = Join-Path $ClaudeDir '.kirakit-profile'
$ManifestPath = Join-Path $ClaudeDir '.kirakit-manifest'
$OriginalsPath = Join-Path $ClaudeDir '.kirakit-originals'
$PermissionsPath = Join-Path $ClaudeDir '.kirakit-permissions'
$PlaceholderKeys = @('user', 'they', 'them', 'their', 'language', 'co_author', 'assistant_name', 'assistant_email',
    'assistant_signing_key', 'assistant_github', 'analyst', 'analyst_github', 'coder', 'coder_name', 'coder_email',
    'coder_signing_key', 'coder_github', 'committer', 'committer_name', 'committer_email', 'committer_signing_key',
    'complete_approved_prs', 'start_verified_specs', 'any_committer_key', 'team_github')

$script:Work = $null
$script:BackupDir = $null
$script:Mode = 'copy'
$script:Src = $null
$script:BuildDir = $null
$script:SettingsBackedUp = $false
$script:Installed = New-Object System.Collections.Generic.List[string]
$script:OriginalsNew = New-Object System.Collections.Generic.List[string]
$script:Removed = New-Object System.Collections.Generic.List[string]

function Write-KiraLog([string]$Message) {
    Write-Host "kirakit: $Message"
}

function Write-DryRun([string]$Message) {
    Write-Host "[dry-run] $Message"
}

function Read-KiraText([string]$Path) {
    return [IO.File]::ReadAllText($Path, $Utf8)
}

function Write-KiraText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

# Lines of a text, without the final newline; an empty text has no lines. Callers wrap the
# result in @() so that one line or none still gives an array.
function Split-KiraLine([string]$Text) {
    $t = $Text.Replace("`r`n", "`n")
    if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    if ($t -eq '') { return }
    return $t -split "`n"
}

function Join-KiraLine([string[]]$Lines) {
    return ($Lines -join $Nl) + $Nl
}

# The branch or tag to fetch without a clone: KIRAKIT_REF, else the version this copy was
# released with, else the highest vX.Y.Z tag of the repository, else main.
function Get-KiraRef {
    if ($env:KIRAKIT_REF) { return $env:KIRAKIT_REF }
    if ($KiraVersion) { return $KiraVersion }
    # Windows PowerShell 5.1 turns a native command's error output into a terminating error.
    $ErrorActionPreference = 'Continue'
    $best = $null
    $bestTag = 'main'
    foreach ($line in @(& git ls-remote --tags --refs -- $Repo 'v*' 2>$null)) {
        if ($line -match 'refs/tags/(v(\d+)\.(\d+)\.(\d+))$') {
            $tag = $Matches[1]
            $version = New-Object Version ([int]$Matches[2]), ([int]$Matches[3]), ([int]$Matches[4])
            if (-not $best -or $version -gt $best) {
                $best = $version
                $bestTag = $tag
            }
        }
    }
    return $bestTag
}

function Get-KiraWorkDir {
    if (-not $script:Work) {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('kirakit.' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $path | Out-Null
        $script:Work = $path
    }
    return $script:Work
}

function Initialize-KiraDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) { Write-DryRun "create directory $Path"; return }
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-KiraLinkTarget([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'SymbolicLink') { return [string](@($item.Target)[0]) }
    return $null
}

function Test-KiraPresent([string]$Path) {
    return (Test-Path -LiteralPath $Path) -or [bool](Get-KiraLinkTarget $Path)
}

# Move PATH (or copy it, with -CopyOnly) into this run's backup directory, under PREFIX
# followed by PATH relative to ROOT. Returns the backup path.
function Backup-KiraPath([string]$Path, [string]$Root = $ClaudeDir, [string]$Prefix = '', [switch]$CopyOnly) {
    if (-not $script:BackupDir) {
        # Never reuse the directory of an earlier run started within the same second.
        $base = Join-Path (Join-Path $ClaudeDir '.kirakit-backups') (Get-Date -Format 'yyyyMMdd-HHmmss')
        $dir = $base
        $n = 1
        while (Test-Path -LiteralPath $dir) { $dir = "$base-$n"; $n++ }
        $script:BackupDir = $dir
    }
    $rel = $Path.Substring($Root.Length).TrimStart('\', '/')
    $dest = Join-Path $script:BackupDir ($Prefix.Replace('/', $Sep) + $rel)
    Write-KiraLog "backup: $Path -> $dest"
    Initialize-KiraDirectory (Split-Path -Parent $dest)
    if ($DryRun) {
        Write-DryRun "$(if ($CopyOnly) { 'copy' } else { 'move' }) $Path to $dest"
    } elseif ($CopyOnly) {
        Copy-Item -LiteralPath $Path -Destination $dest -Recurse
    } else {
        Move-Item -LiteralPath $Path -Destination $dest
    }
    return $dest
}

function Get-KiraTreeHash([string]$Path) {
    # Relative paths from the resolved name, which may differ from PATH (e.g. short names).
    $base = (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd('\', '/')
    $entries = Get-ChildItem -LiteralPath $base -Recurse -File -Force | ForEach-Object {
        $_.FullName.Substring($base.Length) + '|' + (Get-FileHash -LiteralPath $_.FullName).Hash
    } | Sort-Object
    return (@($entries) -join $Nl)
}

# Whether TARGET is already an identical copy of SOURCE (a file or a directory).
function Test-KiraSameCopy([string]$Source, [string]$Destination) {
    if (Get-KiraLinkTarget $Destination) { return $false }
    if (Test-Path -LiteralPath $Source -PathType Container) {
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { return $false }
        return (Get-KiraTreeHash $Source) -eq (Get-KiraTreeHash $Destination)
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $Source).Hash -eq (Get-FileHash -LiteralPath $Destination).Hash
}

# Whether PATH is the first tab-separated field of a line of FILE.
function Test-KiraListed([string]$File, [string]$Path) {
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    foreach ($line in [IO.File]::ReadAllLines($File, $Utf8)) {
        if ($line.Split("`t")[0] -eq $Path) { return $true }
    }
    return $false
}

# Link or copy SOURCE (a file or a directory) to DESTINATION, backing up anything else there.
# Destinations in the configuration directory (no ROOT) are recorded in the manifest for
# -Uninstall, with the backup of what was there before kirakit so that -Uninstall can
# restore it.
function Install-KiraFile([string]$Source, [string]$Destination, [string]$Root = '', [string]$Prefix = '') {
    if (-not $Root) { $script:Installed.Add($Destination) }
    if ($script:Mode -eq 'link') {
        if ((Get-KiraLinkTarget $Destination) -eq $Source) { Write-KiraLog "up to date: $Destination"; return }
    } elseif (Test-KiraSameCopy $Source $Destination) {
        Write-KiraLog "up to date: $Destination"
        return
    }

    if (Test-KiraPresent $Destination) {
        $backupRoot = if ($Root) { $Root } else { $ClaudeDir }
        $dest = Backup-KiraPath -Path $Destination -Root $backupRoot -Prefix $Prefix
        if (-not $Root -and -not (Test-KiraListed $ManifestPath $Destination) -and -not (Test-KiraListed $OriginalsPath $Destination)) {
            $script:OriginalsNew.Add("$Destination$Tab$dest")
        }
    }
    Initialize-KiraDirectory (Split-Path -Parent $Destination)
    if ($script:Mode -eq 'link') {
        Write-KiraLog "link: $Destination -> $Source"
        if ($DryRun) { Write-DryRun "link $Destination to $Source"; return }
        New-Item -ItemType SymbolicLink -Path $Destination -Value $Source | Out-Null
    } else {
        Write-KiraLog "copy: $Source -> $Destination"
        if ($DryRun) { Write-DryRun "copy $Source to $Destination"; return }
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    }
}

# --- Profile -------------------------------------------------------------------------------

function Test-KiraCoAuthor([string]$Value) {
    return $Value -eq '' -or $Value -match '^[^<>]+ <[^<>\s]+@[^<>\s]+>$'
}

function Test-KiraCanPrompt {
    try { return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { return $false }
}

function Read-KiraAnswer([string]$Question, [string]$Default = '') {
    $prompt = if ($Default) { "$Question [$Default]" } else { $Question }
    $answer = Read-Host $prompt
    if ($answer) { return $answer }
    return $Default
}

function Read-KiraGender([string]$Current) {
    $default = switch ($Current) { 'male' { '1' } 'female' { '2' } 'nonbinary' { '3' } default { '4' } }
    Write-Host 'How should Kira refer to you?'
    Write-Host '  1) male (he/him)'
    Write-Host '  2) female (she/her)'
    Write-Host '  3) non-binary (they/them)'
    Write-Host '  4) prefer not to say (they/them)'
    while ($true) {
        switch (Read-KiraAnswer 'Choice' $default) {
            '1' { return 'male' }
            '2' { return 'female' }
            '3' { return 'nonbinary' }
            '4' { return 'unspecified' }
        }
    }
}

function Test-KiraGithub([string]$Value) {
    return $Value -cnotmatch '[^A-Za-z0-9-]'
}

# Ask for a git identity, such as WHOSE = "Assistant's"; return "NAME <EMAIL>", or nothing when
# no email is given.
function Read-KiraIdentity([string]$Whose, [string]$DefaultName, [string]$Current) {
    if ($Current -match '^(.+) <(.+)>$') {
        $currentName = $Matches[1]
        $currentEmail = $Matches[2]
    } else {
        $currentName = $DefaultName
        $currentEmail = ''
    }
    $identityName = Read-KiraAnswer "$Whose name" $currentName
    while ($true) {
        $identityEmail = Read-KiraAnswer "$Whose email (empty: none)" $currentEmail
        if (-not $identityEmail) { return '' }
        $value = "$identityName <$identityEmail>"
        if (Test-KiraCoAuthor $value) { return $value }
        Write-Host 'Expected an email address such as kira@example.com.'
    }
}

# Ask for a GitHub login, such as WHOSE = "Assistant's".
function Read-KiraGithub([string]$Whose, [string]$Current) {
    while ($true) {
        $login = Read-KiraAnswer "$Whose GitHub login (empty: none)" $Current
        if (Test-KiraGithub $login) { return $login }
        Write-Host 'Expected a GitHub login (letters, digits and hyphens).'
    }
}

function Read-KiraAnalyst([string]$Current) {
    while ($true) {
        $answer = Read-KiraAnswer 'Add Iris, an analyst who clarifies ideas and writes specifications? (y/n)' $Current
        if ($answer -match '^[Yy]') { return 'yes' }
        if ($answer -match '^[Nn]') { return 'no' }
    }
}

function Read-KiraTrailer([string]$Current) {
    while ($true) {
        $answer = Read-KiraAnswer 'Add Co-Authored-By trailers to commit messages? (y/n)' $Current
        if ($answer -match '^[Yy]') { return 'yes' }
        if ($answer -match '^[Nn]') { return 'no' }
    }
}

# Expand a leading "~/" so that the saved path does not depend on the shell.
function Expand-KiraHome([string]$Path) {
    if ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) { return (Join-Path $HOME $Path.Substring(2)) }
    return $Path
}

function Read-KiraProfile {
    $saved = @{}
    if (Test-Path -LiteralPath $ProfilePath) {
        foreach ($line in [IO.File]::ReadAllLines($ProfilePath, $Utf8)) {
            $i = $line.IndexOf('=')
            if ($i -gt 0) { $saved[$line.Substring(0, $i)] = $line.Substring($i + 1) }
        }
    }
    if ($saved.ContainsKey('assistant_name')) {
        $saved.assistant = if ($saved['assistant_email']) { "$($saved.assistant_name) <$($saved.assistant_email)>" } else { '' }
    } elseif ($saved.ContainsKey('co_author')) {
        # Profiles before the assistant identity: the co-author was the assistant.
        $saved.assistant = $saved.co_author
        $saved.co_author_trailer = if ($saved.co_author) { 'yes' } else { 'no' }
    }
    # Profiles before the analyst: the team had none, and the question is not asked again.
    if ($saved.Count -gt 0 -and -not $saved.ContainsKey('analyst')) {
        $saved.analyst = 'no'
        $saved.analyst_github = ''
    }
    # Profiles before the coder: the team had none, and the question is not asked again.
    if ($saved.Count -gt 0 -and -not $saved.ContainsKey('coder')) {
        $saved.coder = ''
        $saved.coder_signing_key = ''
        $saved.coder_github = ''
    }
    return $saved
}

# Resolve the profile from parameters, the saved profile, then questions.
function Get-KiraProfile {
    $saved = Read-KiraProfile
    $given = @{
        name                  = $Bound.ContainsKey('Name')
        gender                = $Bound.ContainsKey('Gender')
        language              = $Bound.ContainsKey('Language')
        assistant             = $Bound.ContainsKey('Assistant') -or $Bound.ContainsKey('CoAuthor')
        assistant_signing_key = $Bound.ContainsKey('AssistantSigningKey')
        assistant_github      = $Bound.ContainsKey('AssistantGithub')
        # -CoAuthor predates the assistant identity: it also asks for the trailer.
        co_author_trailer     = $NoCoAuthor -or $Bound.ContainsKey('CoAuthor')
        # An analyst's account means an analyst, unless -NoAnalyst says otherwise.
        analyst               = $Analyst -or $NoAnalyst -or [bool]$AnalystGithub
        analyst_github        = $Bound.ContainsKey('AnalystGithub')
        coder                 = $Bound.ContainsKey('Coder')
        coder_signing_key     = $Bound.ContainsKey('CoderSigningKey')
        coder_github          = $Bound.ContainsKey('CoderGithub')
    }
    $result = @{
        name                  = if ($given.name) { $Name } elseif ($saved.ContainsKey('name')) { $saved.name } else { '' }
        gender                = if ($given.gender) { $Gender } elseif ($saved.ContainsKey('gender')) { $saved.gender } else { 'unspecified' }
        language              = if ($given.language) { $Language } elseif ($saved.ContainsKey('language')) { $saved.language } else { 'auto' }
        assistant             = if ($Bound.ContainsKey('Assistant')) { $Assistant } elseif ($Bound.ContainsKey('CoAuthor')) { $CoAuthor } elseif ($saved.ContainsKey('assistant')) { $saved.assistant } else { '' }
        assistant_signing_key = if ($given.assistant_signing_key) { $AssistantSigningKey } elseif ($saved.ContainsKey('assistant_signing_key')) { $saved.assistant_signing_key } else { '' }
        assistant_github      = if ($given.assistant_github) { $AssistantGithub } elseif ($saved.ContainsKey('assistant_github')) { $saved.assistant_github } else { '' }
        analyst               = if ($NoAnalyst) { 'no' } elseif ($Analyst -or $AnalystGithub) { 'yes' } elseif ($saved.ContainsKey('analyst')) { $saved.analyst } else { 'no' }
        analyst_github        = if ($given.analyst_github) { $AnalystGithub } elseif ($saved.ContainsKey('analyst_github')) { $saved.analyst_github } else { '' }
        coder                 = if ($given.coder) { $Coder } elseif ($saved.ContainsKey('coder')) { $saved.coder } else { '' }
        coder_signing_key     = if ($given.coder_signing_key) { $CoderSigningKey } elseif ($saved.ContainsKey('coder_signing_key')) { $saved.coder_signing_key } else { '' }
        coder_github          = if ($given.coder_github) { $CoderGithub } elseif ($saved.ContainsKey('coder_github')) { $saved.coder_github } else { '' }
        style                 = if ($DefaultStyle) { $DefaultStyle } elseif ($saved.ContainsKey('style') -and $saved.style) { $saved.style } else { 'kira-cozy' }
    }
    # R3: releases stay behind a prompt unless asked; not a question, an option.
    $result.allow_releases = if ($AllowReleases) { 'yes' } elseif ($NoAllowReleases) { 'no' } elseif ($saved.ContainsKey('allow_releases') -and $saved.allow_releases -eq 'yes') { 'yes' } else { 'no' }
    # Pull requests wait for the user unless asked; not a question, an option.
    $result.complete_approved_prs = if ($CompleteApprovedPrs) { 'yes' } elseif ($NoCompleteApprovedPrs) { 'no' } elseif ($saved.ContainsKey('complete_approved_prs') -and $saved.complete_approved_prs -eq 'yes') { 'yes' } else { 'no' }
    # Specifications wait for the user unless asked; not a question, an option.
    $result.start_verified_specs = if ($StartVerifiedSpecs) { 'yes' } elseif ($NoStartVerifiedSpecs) { 'no' } elseif ($saved.ContainsKey('start_verified_specs') -and $saved.start_verified_specs -eq 'yes') { 'yes' } else { 'no' }
    $defaultTrailer = if ($result.assistant) { 'yes' } else { 'no' }
    $result.co_author_trailer = if ($NoCoAuthor) { 'no' } elseif ($Bound.ContainsKey('CoAuthor')) { 'yes' } elseif ($saved.ContainsKey('co_author_trailer')) { $saved.co_author_trailer } else { $defaultTrailer }

    $missing = @()
    foreach ($key in @('name', 'gender', 'language', 'assistant', 'assistant_signing_key', 'assistant_github', 'co_author_trailer', 'analyst', 'analyst_github', 'coder', 'coder_signing_key', 'coder_github')) {
        # Meaningless without an assistant identity, unless it is about to be asked.
        if (($key -ne 'assistant' -and $key.StartsWith('assistant')) -or $key -eq 'co_author_trailer') {
            if ($missing -notcontains 'assistant' -and -not $result.assistant) { continue }
        }
        # Meaningless without an analyst, unless one is about to be asked for.
        if ($key -eq 'analyst_github' -and $missing -notcontains 'analyst' -and $result.analyst -ne 'yes') { continue }
        # Meaningless without a coder identity, unless it is about to be asked.
        if ($key -ne 'coder' -and $key.StartsWith('coder') -and $missing -notcontains 'coder' -and -not $result.coder) { continue }
        if (-not $given[$key] -and ($Reconfigure -or -not $saved.ContainsKey($key))) { $missing += $key }
    }
    $save = $true
    if ($missing.Count -gt 0 -and -not (Test-KiraCanPrompt)) {
        Write-KiraLog "no terminal to ask for: $($missing -join ' '); using defaults (see Get-Help)"
        # The optional assistant and analyst values default to empty or no; only a missing required value keeps
        # the profile unsaved, so that a later run on a terminal asks for it.
        foreach ($key in $missing) {
            if (@('name', 'gender', 'language', 'assistant') -contains $key) { $save = $false }
        }
        $missing = @()
    }
    foreach ($key in $missing) {
        switch ($key) {
            'name' { $result.name = Read-KiraAnswer 'How should Kira call you?' $result.name }
            'gender' { $result.gender = Read-KiraGender $result.gender }
            'language' { $result.language = Read-KiraAnswer 'Which language should Kira answer in? (auto follows the conversation)' $result.language }
            'assistant' { $result.assistant = Read-KiraIdentity "Assistant's" 'Kira' $result.assistant }
            'assistant_signing_key' {
                if ($result.assistant) { $result.assistant_signing_key = Read-KiraAnswer "Assistant's public SSH signing key (empty: the assistant does not commit as itself)" $result.assistant_signing_key }
            }
            'assistant_github' { if ($result.assistant) { $result.assistant_github = Read-KiraGithub "Assistant's" $result.assistant_github } }
            'co_author_trailer' {
                $defaultTrailer = if ($result.assistant) { 'yes' } else { 'no' }
                $current = if ($saved.ContainsKey('co_author_trailer')) { $saved.co_author_trailer } else { $defaultTrailer }
                if ($result.assistant) { $result.co_author_trailer = Read-KiraTrailer $current }
            }
            'analyst' { $result.analyst = Read-KiraAnalyst $result.analyst }
            # R8: the analyst never commits, so she has a GitHub account but no signing key.
            'analyst_github' { if ($result.analyst -eq 'yes') { $result.analyst_github = Read-KiraGithub "Analyst's" $result.analyst_github } }
            'coder' { $result.coder = Read-KiraIdentity "Coder's" 'Cleo' $result.coder }
            # The other coder values mean nothing without a coder identity.
            'coder_signing_key' {
                if ($result.coder) { $result.coder_signing_key = Read-KiraAnswer "Coder's public SSH signing key (empty: the coder does not commit as itself)" $result.coder_signing_key }
            }
            'coder_github' { if ($result.coder) { $result.coder_github = Read-KiraGithub "Coder's" $result.coder_github } }
        }
    }
    if ($result.analyst -ne 'yes') {
        $result.analyst = 'no'
        $result.analyst_github = ''
    }
    if (-not $result.assistant) {
        $result.assistant_signing_key = ''
        $result.assistant_github = ''
        $result.co_author_trailer = 'no'
    }
    $result.assistant_signing_key = Expand-KiraHome $result.assistant_signing_key
    if (-not $result.coder) {
        $result.coder_signing_key = ''
        $result.coder_github = ''
    }
    $result.coder_signing_key = Expand-KiraHome $result.coder_signing_key
    $result.co_author = if ($result.co_author_trailer -eq 'yes') { $result.assistant } else { '' }
    if ($result.assistant -match '^(.+) <(.+)>$') {
        $assistantName = $Matches[1]; $assistantEmail = $Matches[2]
    } else {
        $assistantName = ''; $assistantEmail = ''
    }

    # The launchers are not installed on Windows; their settings, made by get-kira.sh, are kept.
    # A launcher location is saved only when get-kira.sh saved one: never a computed default.
    $assistantStyle = if ($saved.ContainsKey('assistant_style')) { $saved.assistant_style } else { '' }
    $launcherDirs = ''
    foreach ($key in @('bin_dir', 'color_scheme_dir')) {
        if ($saved.ContainsKey($key) -and $saved[$key]) { $launcherDirs += "$key=$($saved[$key])$Nl" }
    }

    if (-not $save) { return $result }
    $text ="name=$($result.name)${Nl}gender=$($result.gender)${Nl}language=$($result.language)${Nl}" +
        "assistant_name=$assistantName${Nl}assistant_email=$assistantEmail${Nl}" +
        "assistant_signing_key=$($result.assistant_signing_key)${Nl}assistant_github=$($result.assistant_github)${Nl}" +
        "co_author_trailer=$($result.co_author_trailer)${Nl}analyst=$($result.analyst)${Nl}" +
        "analyst_github=$($result.analyst_github)${Nl}coder=$($result.coder)${Nl}" +
        "coder_signing_key=$($result.coder_signing_key)${Nl}coder_github=$($result.coder_github)${Nl}" +
        "allow_releases=$($result.allow_releases)${Nl}complete_approved_prs=$($result.complete_approved_prs)${Nl}" +
        "start_verified_specs=$($result.start_verified_specs)${Nl}style=$($result.style)${Nl}" +
        "assistant_style=$assistantStyle$Nl" + $launcherDirs
    $current = if (Test-Path -LiteralPath $ProfilePath) { Read-KiraText $ProfilePath } else { $null }
    if ($current -ne $text) {
        Write-KiraLog "save profile: $ProfilePath"
        if ($DryRun) {
            Write-DryRun "write $($text.Trim().Replace($Nl, ' ')) to $ProfilePath"
        } else {
            Initialize-KiraDirectory $ClaudeDir
            Write-KiraText $ProfilePath $text
        }
    }
    return $result
}

# R8: warn about a signing key that is not there; the installer never creates one.
# Test-KiraSigningKey WHO KEY, such as WHO = "the assistant".
function Test-KiraSigningKey([string]$Who, [string]$Key) {
    if (-not $Key) { return }
    if (-not (Test-Path -LiteralPath $Key -PathType Leaf)) {
        Write-KiraLog "warning: $Who's signing key $Key does not exist; $Who cannot commit as itself until it does"
    } elseif (-not (Test-Path -LiteralPath ($Key -replace '\.pub$', '') -PathType Leaf)) {
        Write-KiraLog "warning: no private key next to $Key; $Who cannot sign with it"
    }
}

# --- Build (mirrors scripts/build.sh) -------------------------------------------------------

function Get-KiraValue($UserProfile) {
    $assistant = [string]$UserProfile['assistant']
    $signingKey = [string]$UserProfile['assistant_signing_key']
    $github = [string]$UserProfile['assistant_github']
    # The analyst's account means nothing without an analyst.
    $analystValue = if ($UserProfile['analyst'] -eq 'yes') { 'yes' } else { '' }
    $analystGithub = if ($analystValue) { [string]$UserProfile['analyst_github'] } else { '' }
    $coderValue = [string]$UserProfile['coder']
    # Nor do the coder's key and account without a coder.
    $coderSigningKey = if ($coderValue) { [string]$UserProfile['coder_signing_key'] } else { '' }
    $coderGithub = if ($coderValue) { [string]$UserProfile['coder_github'] } else { '' }
    foreach ($value in @($UserProfile.name, $UserProfile.language, $UserProfile.co_author, $assistant, $signingKey, $coderValue,
            $coderSigningKey)) {
        if ($value -match "`n|\{\{|\}\}") { throw "invalid value: $value" }
    }
    switch ($UserProfile.gender) {
        'male' { $they = 'he'; $them = 'him'; $their = 'his'; $adjective = 'male ' }
        'female' { $they = 'she'; $them = 'her'; $their = 'her'; $adjective = 'female ' }
        'nonbinary' { $they = 'they'; $them = 'them'; $their = 'their'; $adjective = 'non-binary ' }
        'unspecified' { $they = 'they'; $them = 'them'; $their = 'their'; $adjective = '' }
        default { throw "unknown gender: $($UserProfile.gender)" }
    }
    $user = "a ${adjective}staff software developer"
    if ($UserProfile.name) { $user = "$($UserProfile.name), $user" }
    $answerLanguage = $UserProfile.language
    if ($answerLanguage -eq '' -or $answerLanguage -eq 'auto') { $answerLanguage = 'the language of the conversation' }

    $coAuthorValue = $UserProfile.co_author
    if (-not (Test-KiraCoAuthor $coAuthorValue)) { throw "invalid co-author: $coAuthorValue (expected `"NAME <EMAIL>`")" }
    if ($assistant -eq '') {
        $assistantName = ''; $assistantEmail = ''
    } elseif ($assistant -match '^(.+) <(.+@.+)>$') {
        $assistantName = $Matches[1]; $assistantEmail = $Matches[2]
    } else {
        throw "invalid assistant: $assistant (expected `"NAME <EMAIL>`")"
    }
    if ($coderValue -eq '') {
        $coderName = ''; $coderEmail = ''
    } elseif ($coderValue -match '^(.+) <(.+@.+)>$') {
        $coderName = $Matches[1]; $coderEmail = $Matches[2]
    } else {
        throw "invalid coder: $coderValue (expected `"NAME <EMAIL>`")"
    }
    foreach ($login in @($github, $analystGithub, $coderGithub)) {
        if ($login -cmatch '[^A-Za-z0-9-]') { throw "invalid GitHub login: $login" }
    }
    return @{
        user = $user; they = $they; them = $them; their = $their; language = $answerLanguage
        co_author = $coAuthorValue; assistant_name = $assistantName; assistant_email = $assistantEmail
        assistant_signing_key = $signingKey; assistant_github = $github
        analyst = $analystValue; analyst_github = $analystGithub
        coder = $coderValue; coder_name = $coderName; coder_email = $coderEmail
        coder_signing_key = $coderSigningKey; coder_github = $coderGithub
        # With a coder, the committer is the coder, who writes and commits the code by default;
        # the assistant commits with its own keys only the code it writes at the user's explicit
        # request, or the coder's work when she has no key.
        committer = if ($coderValue) { 'the coder' } else { 'the assistant' }
        committer_name = if ($coderValue) { $coderName } else { $assistantName }
        committer_email = if ($coderValue) { $coderEmail } else { $assistantEmail }
        committer_signing_key = if ($coderValue) { $coderSigningKey } else { $signingKey }
        # With a coder, the assistant commits the code she wrote at the user's explicit request
        # with her own key, whatever the coder's key.
        any_committer_key = if (($coderValue -and ($coderSigningKey -or $signingKey)) -or (-not $coderValue -and $signingKey)) { 'yes' } else { '' }
        complete_approved_prs = if ($UserProfile['complete_approved_prs'] -eq 'yes') { 'yes' } else { '' }
        # Verified specifications start without the user only with both an analyst, who writes
        # them, and a coder, whose team has the lead's kira agent that verifies them.
        start_verified_specs = if ($UserProfile['start_verified_specs'] -eq 'yes' -and $analystValue -and $coderValue) { 'yes' } else { '' }
        # The team's accounts: the members' sessions mark what they write as these accounts.
        team_github = if ($github -or $analystGithub -or $coderGithub) { 'yes' } else { '' }
    }
}

# Fill the placeholders of LINES; a line holding only a placeholder that expands to nothing
# is removed. Lines between {{#KEY}} and {{/KEY}} are kept only when KEY is not empty, and
# lines between {{^KEY}} and {{/KEY}} only when it is (mirrors render in scripts/build.sh).
function Format-KiraLine([string[]]$Lines, $Values, [string]$Origin) {
    $out = New-Object System.Collections.Generic.List[string]
    $open = New-Object System.Collections.Generic.List[string]
    $shown = New-Object System.Collections.Generic.List[bool]
    $hidden = 0
    for ($n = 0; $n -lt $Lines.Count; $n++) {
        $line = $Lines[$n]
        if ($line -cmatch '^\{\{([#^/])([a-z_]+)\}\}$') {
            $kind = $Matches[1]; $key = $Matches[2]
            if ($PlaceholderKeys -cnotcontains $key) { throw "${Origin}:$($n + 1): unknown block $key" }
            if ($kind -eq '/') {
                if ($open.Count -eq 0 -or $open[$open.Count - 1] -cne $key) { throw "${Origin}:$($n + 1): unexpected {{/$key}}" }
                if (-not $shown[$shown.Count - 1]) { $hidden-- }
                $open.RemoveAt($open.Count - 1); $shown.RemoveAt($shown.Count - 1)
            } else {
                $set = [string]$Values[$key] -ne ''
                $visible = if ($kind -eq '#') { $set } else { -not $set }
                $open.Add($key); $shown.Add($visible)
                if (-not $visible) { $hidden++ }
            }
            continue
        }
        if ($hidden -gt 0) { continue }
        $keep = $true
        foreach ($key in $PlaceholderKeys) {
            $placeholder = '{{' + $key + '}}'
            if ($line -eq $placeholder -and $Values[$key] -eq '') { $keep = $false; break }
            $line = $line.Replace($placeholder, $Values[$key])
        }
        if ($keep) { $out.Add($line) }
    }
    if ($open.Count -gt 0) { throw "${Origin}:end: missing {{/$($open[$open.Count - 1])}}" }
    return $out.ToArray()
}

# A file that renders to nothing, such as a template wholly inside a block that is dropped for
# this profile, is not written, and an earlier build of it is removed.
function Write-KiraRendered([string]$Path, [string[]]$Lines, $Values, [string]$Origin) {
    $text = Join-KiraLine @(Format-KiraLine $Lines $Values $Origin)
    if ($text -notmatch '\S') {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        return
    }
    if ($text -match '\{\{[^}]*\}\}') { throw "${Origin}: unknown placeholder $($Matches[0])" }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    Write-KiraText $Path $text
}

function Build-KiraStyle([string]$Out, [string]$PersonaName, [string[]]$CoreLines, $Values) {
    $overlay = Join-Path (Join-Path $script:Src 'personas') "$PersonaName.md"
    $lines = @(Split-KiraLine (Read-KiraText $overlay))
    $end = -1
    if ($lines.Count -gt 0 -and $lines[0] -eq '---') {
        for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq '---') { $end = $i; break } }
    }
    if ($end -lt 0) { throw "${overlay}: missing front matter" }

    # Overlay body, without the blank lines that follow the front matter.
    $body = New-Object System.Collections.Generic.List[string]
    for ($i = $end + 1; $i -lt $lines.Count; $i++) {
        if ($body.Count -eq 0 -and $lines[$i] -eq '') { continue }
        $body.Add($lines[$i])
    }
    $bodyText = $body.ToArray() -join $Nl

    $merged = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -le $end; $i++) { $merged.Add($lines[$i]) }
    $merged.Add('')
    foreach ($line in $CoreLines) {
        $i = $line.IndexOf('{{overlay}}')
        if ($i -ge 0) { $line = $line.Substring(0, $i) + $bodyText + $line.Substring($i + 11) }
        $merged.Add($line)
    }
    Write-KiraRendered (Join-Path (Join-Path $Out 'output-styles') "$PersonaName.md") $merged.ToArray() $Values $overlay
}

# Render a team member's persona (team\NAME.md), written once, into both an output style and
# an agent with the same body (mirrors build_member in scripts/build.sh).
function Build-KiraMember([string]$Out, [string]$Path, $Values) {
    $member = [IO.Path]::GetFileNameWithoutExtension($Path)
    # The member's command is named after her: it must not replace a skill of claude/skills/.
    if (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $script:Src 'claude') 'skills') $member) -PathType Container) {
        throw "${Path}: the command of team member $member has the same name as the skill claude/skills/$member"
    }
    $style = Join-Path (Join-Path $Out 'output-styles') "$member.md"
    $agent = Join-Path (Join-Path $Out 'agents') "$member.md"
    $command = Join-Path (Join-Path $Out 'skills') $member
    $lines = @(Format-KiraLine @(Split-KiraLine (Read-KiraText $Path)) $Values $Path)
    $text = Join-KiraLine $lines
    if ($text -notmatch '\S') {
        foreach ($file in @($style, $agent)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
        if (Test-Path -LiteralPath $command) { Remove-Item -LiteralPath $command -Recurse -Force }
        return
    }
    if ($text -match '\{\{[^}]*\}\}') { throw "${Path}: unknown placeholder $($Matches[0])" }
    $end = -1
    if ($lines[0] -eq '---') {
        for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq '---') { $end = $i; break } }
    }
    $fields = @{}
    for ($i = 1; $i -lt $end; $i++) {
        $j = $lines[$i].IndexOf(': ')
        if ($j -gt 0 -and -not $fields.ContainsKey($lines[$i].Substring(0, $j))) { $fields[$lines[$i].Substring(0, $j)] = $lines[$i].Substring($j + 2) }
    }
    if ($end -lt 0 -or -not $fields['name'] -or -not $fields['description'] -or -not $fields['delegate']) {
        throw "${Path}: missing front matter with name, description and delegate"
    }
    if (-not $fields['model']) { throw "${Path}: missing model in the front matter" }
    # Body, without the blank lines that follow the front matter.
    $body = New-Object System.Collections.Generic.List[string]
    for ($i = $end + 1; $i -lt $lines.Count; $i++) {
        if ($body.Count -eq 0 -and $lines[$i] -eq '') { continue }
        $body.Add($lines[$i])
    }
    foreach ($file in @($style, $agent)) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null }
    Write-KiraText $style (Join-KiraLine (@('---', "name: $($fields.name)", "description: $($fields.description)", 'keep-coding-instructions: true', '---', '') + $body.ToArray()))
    Write-KiraText $agent (Join-KiraLine (@('---', "name: $member", "description: $($fields.delegate)", "model: $($fields.model)", '---', '') + $body.ToArray()))
    # A command that lets the user talk to the member directly: a skill forked into her agent,
    # which only the user can run. $ARGUMENTS is filled by Claude Code with the user's request.
    if (Test-Path -LiteralPath $command) { Remove-Item -LiteralPath $command -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $command | Out-Null
    Write-KiraText (Join-Path $command 'SKILL.md') (Join-KiraLine @(
            '---', "name: $member",
            "description: Talk to $($fields.name) directly: she handles your request in her own persona and answers you.",
            "model: $($fields.model)", 'context: fork', "agent: $member", 'disable-model-invocation: true', '---', '',
            "The user addresses you directly with the ``/$member`` command, from the lead's conversation.",
            'Their request:',
            '',
            '$ARGUMENTS',
            '',
            'Handle it as one exchange, in your own persona and under your own rules, and end with your',
            'answer to the user, written for the user, your questions included.',
            '',
            'When the request above is empty, answer in one line asking what the user wants from you.'))
}

function Build-KiraOutput($UserProfile) {
    if ($script:Mode -eq 'link' -and -not $DryRun) {
        $script:BuildDir = Join-Path $script:Src 'dist'
    } else {
        $script:BuildDir = Join-Path (Get-KiraWorkDir) 'dist'
    }
    $out = $script:BuildDir
    $values = Get-KiraValue $UserProfile

    $core = Join-Path (Join-Path $script:Src 'personas') '_core.md'
    $coreText = Read-KiraText $core
    if (-not $coreText.Contains('{{overlay}}')) { throw "${core}: missing {{overlay}} marker" }
    $coreLines = @(Split-KiraLine $coreText)
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Src 'personas') -Filter '*.md' -File) {
        if ($file.BaseName.StartsWith('_')) { continue }
        Build-KiraStyle $out $file.BaseName $coreLines $values
    }
    $team = Join-Path $script:Src 'team'
    if (Test-Path -LiteralPath $team) {
        foreach ($file in Get-ChildItem -LiteralPath $team -Filter '*.md' -File) { Build-KiraMember $out $file.FullName $values }
    }

    $claude = Join-Path $script:Src 'claude'
    $skills = Join-Path $claude 'skills'
    if (Test-Path -LiteralPath $skills) {
        foreach ($dir in Get-ChildItem -LiteralPath $skills -Directory) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md'))) { continue }
            $dest = Join-Path (Join-Path $out 'skills') $dir.Name
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $dir.FullName -Destination $dest -Recurse
            foreach ($file in Get-ChildItem -LiteralPath $dest -Recurse -File -Filter '*.md') {
                $origin = Join-Path $dir.FullName $file.FullName.Substring($dest.Length + 1)
                Write-KiraRendered $file.FullName @(Split-KiraLine (Read-KiraText $file.FullName)) $values $origin
            }
            # A skill whose SKILL.md renders to nothing is not built.
            if (-not (Test-Path -LiteralPath (Join-Path $dest 'SKILL.md'))) { Remove-Item -LiteralPath $dest -Recurse -Force }
        }
    }
    $agents = Join-Path $claude 'agents'
    if (Test-Path -LiteralPath $agents) {
        foreach ($file in Get-ChildItem -LiteralPath $agents -Filter '*.md' -File) {
            Write-KiraRendered (Join-Path (Join-Path $out 'agents') $file.Name) @(Split-KiraLine (Read-KiraText $file.FullName)) $values $file.FullName
        }
    }
    $rules = Join-Path $claude 'rules'
    if (Test-Path -LiteralPath $rules) {
        foreach ($file in Get-ChildItem -LiteralPath $rules -Filter '*.md' -File) {
            Write-KiraRendered (Join-Path (Join-Path $out 'rules') $file.Name) @(Split-KiraLine (Read-KiraText $file.FullName)) $values $file.FullName
        }
    }
    $claudeMd = Join-Path $claude 'CLAUDE.md'
    if (Test-Path -LiteralPath $claudeMd) {
        Write-KiraRendered (Join-Path $out 'CLAUDE.md') @(Split-KiraLine (Read-KiraText $claudeMd)) $values $claudeMd
    }
}

# Where an installed file comes from; symbolic links always point into the clone.
function Get-KiraBuiltPath([string]$Relative) {
    $rel = $Relative.Replace('/', $Sep)
    if ($script:Mode -eq 'link') { return Join-Path (Join-Path $script:Src 'dist') $rel }
    return Join-Path $script:BuildDir $rel
}

# --- Install --------------------------------------------------------------------------------

# Install the built file RELATIVE. A file the build left out (a template that renders to
# nothing for this profile) is not installed, and is removed if an earlier run installed it.
function Install-KiraBuilt([string]$Relative, [string]$Destination) {
    if (Test-Path -LiteralPath (Join-Path $script:BuildDir $Relative.Replace('/', $Sep))) {
        Install-KiraFile (Get-KiraBuiltPath $Relative) $Destination
    } elseif (Test-KiraListed $ManifestPath $Destination) {
        Uninstall-KiraFile $Destination
        $script:Removed.Add($Destination)
    }
}

function Install-KiraStyle {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Src 'personas') -Filter '*.md' -File | Sort-Object Name) {
        $styleName = $file.BaseName
        if ($styleName.StartsWith('_')) { continue }
        if ($Persona.Count -gt 0 -and $Persona -notcontains $styleName) { continue }
        Install-KiraBuilt "output-styles/$styleName.md" (Join-Path (Join-Path $ClaudeDir 'output-styles') "$styleName.md")
    }
    # Team members (team\NAME.md) have an output style and an agent; -Persona is for Kira's.
    $team = Join-Path $script:Src 'team'
    if (Test-Path -LiteralPath $team) {
        foreach ($file in Get-ChildItem -LiteralPath $team -Filter '*.md' -File | Sort-Object Name) {
            Install-KiraBuilt "output-styles/$($file.Name)" (Join-Path (Join-Path $ClaudeDir 'output-styles') $file.Name)
        }
    }
}

# Set "outputStyle" in settings.json to the default style, leaving every other setting as it
# is: Claude Code writes to this file too, so it is edited in place, never replaced.
# Copy settings.json to the backups once per run, before its first change.
function Backup-KiraSetting([string]$Settings) {
    if ((Test-Path -LiteralPath $Settings) -and -not $script:SettingsBackedUp) {
        Backup-KiraPath -Path $Settings -CopyOnly | Out-Null
        $script:SettingsBackedUp = $true
    }
}

# TEXT with ENTRY as the first setting, or a new object (mirrors insert_setting in get-kira.sh).
function Add-KiraSetting([string]$Entry, [string]$Text) {
    if ($Text -eq '' -or ($Text -replace '\s', '') -eq '{}') {
        return '{' + $Nl + '  ' + $Entry + $Nl + '}' + $Nl
    }
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    foreach ($line in @(Split-KiraLine $Text)) {
        $i = $line.IndexOf('{')
        if (-not $done -and $i -ge 0) {
            $out.Add($line.Substring(0, $i + 1))
            $out.Add('  ' + $Entry + ',')
            $rest = $line.Substring($i + 1)
            if ($rest -match '[^ \t]') { $out.Add($rest) }
            $done = $true
            continue
        }
        $out.Add($line)
    }
    return Join-KiraLine $out.ToArray()
}

# R11: turn off the attribution Claude Code suggests, so the git rules are the only ones. An
# "attribution" setting the user wrote is left alone (mirrors set_attribution in get-kira.sh).
function Install-KiraAttribution {
    $settings = Join-Path $ClaudeDir 'settings.json'
    $entry = '"attribution": {"commit": "", "pr": ""}'
    $text = if (Test-Path -LiteralPath $settings) { Read-KiraText $settings } else { '' }
    $flat = $text -replace '\s', ''
    if ($flat.Contains('"attribution":{"commit":"","pr":""}') -or $flat.Contains('"attribution":{"pr":"","commit":""}')) {
        Write-KiraLog "up to date: $settings (attribution)"
        return
    }
    if ($flat.Contains('"attribution":')) {
        Write-KiraLog "warning: $settings already sets `"attribution`"; left unchanged. For the git rules alone to apply, set it by hand to: $entry"
        return
    }
    $new = Add-KiraSetting $entry $text
    Backup-KiraSetting $settings
    Write-KiraLog "set attribution: commit and pr off in $settings"
    if (-not $DryRun) {
        Initialize-KiraDirectory $ClaudeDir
        Write-KiraText $settings $new
    }
}

function Install-KiraOutputStyle([string]$Style) {
    $settings = Join-Path $ClaudeDir 'settings.json'
    $styleFile = Join-Path (Join-Path $script:BuildDir 'output-styles') "$Style.md"
    $value = ''
    foreach ($line in @(Split-KiraLine (Read-KiraText $styleFile))) {
        if ($line.StartsWith('name: ')) { $value = $line.Substring(6); break }
    }
    if ($value -eq '' -or $value.Contains('"') -or $value.Contains('\')) { throw "cannot use the name of $Style as outputStyle: $value" }
    $entry = '"outputStyle": "' + $value + '"'

    $exists = Test-Path -LiteralPath $settings
    $text = if ($exists) { Read-KiraText $settings } else { '' }
    if ($text.Contains($entry)) { Write-KiraLog "up to date: $settings (outputStyle)"; return }

    if ($text -match '"outputStyle"\s*:') {
        $new = [regex]::Replace($text, '"outputStyle"\s*:\s*"[^"]*"', $entry.Replace('$', '$$'))
    } else {
        $new = Add-KiraSetting $entry $text
    }

    Backup-KiraSetting $settings
    Write-KiraLog "set outputStyle: $value in $settings"
    if (-not $DryRun) {
        Initialize-KiraDirectory $ClaudeDir
        Write-KiraText $settings $new
    }
}

# The permission rules the members' GitHub accounts need, without duplicates: a rule several
# members need is listed once (#67 R1, R2, R3; #79 R25, R27; mirrors permission_rules in
# get-kira.sh).
function Get-KiraPermissionRule($UserProfile) {
    $rules = New-Object System.Collections.Generic.List[string]
    $assistantLogin = [string]$UserProfile.assistant_github
    $analystLogin = [string]$UserProfile.analyst_github
    $coderLogin = [string]$UserProfile.coder_github
    if ($assistantLogin) {
        $gh = 'GH_TOKEN=$(gh auth token --user ' + $assistantLogin + ') gh'
        foreach ($command in @('issue create', 'issue edit', 'issue comment', 'issue close',
                'pr create', 'pr comment', 'pr review', 'label create')) {
            $rules.Add("Bash($gh ${command}:*)")
        }
        # With a coder, the lead requests the user's review on her pull requests (#79 R27).
        if ($coderLogin) { $rules.Add("Bash($gh pr edit:*)") }
        foreach ($type in @('feat', 'fix', 'docs', 'refactor', 'test', 'chore', 'ci')) {
            $rules.Add("Bash(git push -u origin $type/:*)")
            $rules.Add("Bash(git push origin $type/:*)")
        }
        $rules.Add('Bash(git push origin main)')
        $rules.Add('Bash(git push origin --delete:*)')
        $rules.Add("Bash($gh project item-edit:*)")
        $rules.Add("Bash($gh project item-add:*)")
        if ($UserProfile.allow_releases -eq 'yes') {
            $rules.Add("Bash($gh release create:*)")
            $rules.Add('Bash(git push origin v:*)')
        }
    }
    if ($analystLogin) {
        $gh = 'GH_TOKEN=$(gh auth token --user ' + $analystLogin + ') gh'
        foreach ($command in @('issue create', 'issue edit', 'issue comment', 'issue close',
                'label create', 'project item-edit', 'project item-list')) {
            $rules.Add("Bash($gh ${command}:*)")
        }
    }
    # The coder: her issues, pull requests, work branches and board moves, but not main, which
    # the lead pushes when she merges (#79 R25, D25).
    if ($coderLogin) {
        $gh = 'GH_TOKEN=$(gh auth token --user ' + $coderLogin + ') gh'
        foreach ($command in @('issue create', 'issue edit', 'issue comment',
                'pr create', 'pr comment', 'pr review', 'pr edit')) {
            $rules.Add("Bash($gh ${command}:*)")
        }
        foreach ($type in @('feat', 'fix', 'docs', 'refactor', 'test', 'chore', 'ci')) {
            $rules.Add("Bash(git push -u origin $type/:*)")
            $rules.Add("Bash(git push origin $type/:*)")
        }
        # Only her work branches: a broad --delete rule would also match main.
        foreach ($type in @('feat', 'fix', 'docs', 'refactor', 'test', 'chore', 'ci')) {
            $rules.Add("Bash(git push origin --delete $type/:*)")
        }
        $rules.Add("Bash($gh project item-edit:*)")
        $rules.Add("Bash($gh project item-add:*)")
    }
    $unique = New-Object System.Collections.Generic.List[string]
    foreach ($rule in $rules) {
        if (-not $unique.Contains($rule)) { $unique.Add($rule) }
    }
    return $unique.ToArray()
}

# Whether TEXT has a single "permissions" key and a single "allow" key, whose array opens at
# the end of its line or is empty (mirrors allow_shape in get-kira.sh).
function Test-KiraAllowShape([string]$Text) {
    if (([regex]::Matches($Text, '"permissions"')).Count -ne 1) { return $false }
    if (([regex]::Matches($Text, '"allow"')).Count -ne 1) { return $false }
    foreach ($line in @(Split-KiraLine $Text)) {
        if ($line -cmatch '"allow"\s*:\s*\[\s*(\].*)?$') { return $true }
    }
    return $false
}

# TEXT with RULES added to "permissions.allow", or $null when the shape of TEXT is not one
# that text processing can change safely (#67 R4, R6; mirrors add_permission_rules in
# get-kira.sh).
function Add-KiraPermissionRule([string[]]$Rules, [string]$Text) {
    $last = $Rules.Count - 1
    if ($Text.Length -eq 0 -or ($Text -replace '\s', '') -eq '{}') {
        $out = New-Object System.Collections.Generic.List[string]
        $out.Add('{'); $out.Add('  "permissions": {'); $out.Add('    "allow": [')
        for ($k = 0; $k -le $last; $k++) {
            $out.Add('      "' + $Rules[$k] + '"' + $(if ($k -lt $last) { ',' } else { '' }))
        }
        $out.Add('    ]'); $out.Add('  }'); $out.Add('}')
        return Join-KiraLine $out.ToArray()
    }
    $permissions = ([regex]::Matches($Text, '"permissions"')).Count
    $lines = @(Split-KiraLine $Text)
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    if ($permissions -eq 0) {
        # No permissions key: a new one, as the first setting.
        if (-not $Text.Contains('{')) { return $null }
        foreach ($line in $lines) {
            $i = $line.IndexOf('{')
            if (-not $done -and $i -ge 0) {
                $out.Add($line.Substring(0, $i + 1))
                $out.Add('  "permissions": {')
                $out.Add('    "allow": [')
                for ($k = 0; $k -le $last; $k++) {
                    $out.Add('      "' + $Rules[$k] + '"' + $(if ($k -lt $last) { ',' } else { '' }))
                }
                $out.Add('    ]')
                $out.Add('  },')
                $rest = $line.Substring($i + 1)
                if ($rest -match '[^ \t]') { $out.Add($rest) }
                $done = $true
                continue
            }
            $out.Add($line)
        }
        return Join-KiraLine $out.ToArray()
    }
    if (-not (Test-KiraAllowShape $Text)) { return $null }
    $empty = ($Text -replace '\s', '').Contains('"allow":[]')
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '"allow"[ \t]*:[ \t]*\[')
        if (-not $done -and $m.Success) {
            $end = $m.Index + $m.Length
            $indent = [regex]::Match($line, '^[ \t]*').Value
            $out.Add($line.Substring(0, $end))
            for ($k = 0; $k -le $last; $k++) {
                $out.Add($indent + '  "' + $Rules[$k] + '"' + $(if ($k -lt $last -or -not $empty) { ',' } else { '' }))
            }
            $rest = $line.Substring($end) -replace '^[ \t]*', ''
            if ($rest -ne '') { $out.Add($indent + $rest) }
            $done = $true
            continue
        }
        $out.Add($line)
    }
    return Join-KiraLine $out.ToArray()
}

# TEXT without one occurrence of each of RULES in "permissions.allow", and the comma that
# follows it, or precedes it for the last rule; $null when the shape of TEXT is not
# recognized, or a rule is not alone on its line in the array (#67 R7, R8, R14, R15; mirrors
# remove_permission_rules in get-kira.sh).
function Undo-KiraPermissionRule([string[]]$Rules, [string]$Text) {
    if (-not (Test-KiraAllowShape $Text)) { return $null }
    $wanted = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
    foreach ($rule in $Rules) { $wanted['"' + $rule + '"'] = $true }
    $left = $wanted.Count
    $out = New-Object System.Collections.Generic.List[string]
    $held = $false
    $prev = ''
    $inside = $false
    foreach ($line in @(Split-KiraLine $Text)) {
        if ($inside -and $line -match '^[ \t]*\]') { $inside = $false }
        if ($inside) {
            $key = $line -replace '^[ \t]+', '' -replace '[ \t]+$', ''
            $comma = $key.EndsWith(',')
            if ($comma) { $key = $key.Substring(0, $key.Length - 1) }
            if ($wanted.ContainsKey($key) -and $wanted[$key]) {
                $wanted[$key] = $false
                $left--
                # The last rule: the comma before it goes too.
                if (-not $comma -and $held) { $prev = $prev -replace ',[ \t]*$', '' }
                continue
            }
        }
        if ($line -cmatch '"allow"[ \t]*:[ \t]*\[[ \t]*$') { $inside = $true }
        if ($held) { $out.Add($prev) }
        $prev = $line
        $held = $true
    }
    if ($held) { $out.Add($prev) }
    if ($left -gt 0) { return $null }
    return Join-KiraLine $out.ToArray()
}

# Print RULES as JSON strings, for the user to copy.
function Write-KiraRule([string[]]$Rules) {
    foreach ($rule in $Rules) { Write-Host ('  "' + $rule + '"') }
}

function Clear-KiraPermissionRecord {
    if (Test-Path -LiteralPath $PermissionsPath) {
        Write-KiraLog "remove permission record: $PermissionsPath"
        if ($DryRun) { Write-DryRun "remove $PermissionsPath" } else { Remove-Item -LiteralPath $PermissionsPath -Force }
    }
}

# Bring "permissions.allow" in settings.json in line with the rules the profile expects, and
# record in .kirakit-permissions the rules kirakit inserted. A rule already present that
# kirakit did not insert is the user's: neither recorded nor removed. With -Uninstall, every
# recorded rule is removed (#67 R1 to R10, R12 to R15; mirrors sync_permissions in
# get-kira.sh).
function Sync-KiraPermission($UserProfile, [switch]$Uninstall) {
    $settings = Join-Path $ClaudeDir 'settings.json'
    $exists = Test-Path -LiteralPath $settings
    $text = if ($exists) { Read-KiraText $settings } else { '' }
    $expected = @(if (-not $Uninstall) { Get-KiraPermissionRule $UserProfile })
    $recorded = @(if (Test-Path -LiteralPath $PermissionsPath) {
            [IO.File]::ReadAllLines($PermissionsPath, $Utf8) | Where-Object { $_ -ne '' }
        })
    # R5, R13: an expected rule missing from the file is added, recorded or not.
    $add = @($expected | Where-Object { -not $text.Contains('"' + $_ + '"') })
    # R7, R8: a recorded rule no longer expected is removed, when it is still there.
    $remove = @($recorded | Where-Object { $expected -cnotcontains $_ -and $exists -and $text.Contains('"' + $_ + '"') })

    $changed = $false
    if ($add.Count -eq 0 -and $remove.Count -eq 0) {
        if ($expected.Count -gt 0) { Write-KiraLog "up to date: $settings (permissions)" }
    } else {
        $new = $text
        if ($remove.Count -gt 0) {
            $new = Undo-KiraPermissionRule $remove $new
            if ($null -eq $new) {
                Write-KiraLog "warning: cannot remove the permission rules from $settings safely; left unchanged. Remove them by hand from `"permissions`": {`"allow`": [...]}:"
                Write-KiraRule $remove
                if ($add.Count -gt 0) {
                    Write-KiraLog "warning: nor add the permission rules; add them by hand to `"permissions`": {`"allow`": [...]}:"
                    Write-KiraRule $add
                }
                # R15: the record is kept, so that a later run retries; uninstall drops it.
                if ($Uninstall) { Clear-KiraPermissionRecord }
                return
            }
        }
        if ($add.Count -gt 0) {
            $new = Add-KiraPermissionRule $add $new
            if ($null -eq $new) {
                Write-KiraLog "warning: cannot add the permission rules to $settings safely; left unchanged. Add them by hand to `"permissions`": {`"allow`": [...]}:"
                Write-KiraRule $add
                return
            }
        }
        Backup-KiraSetting $settings
        foreach ($rule in $remove) { Write-KiraLog "remove permission: $rule from $settings" }
        foreach ($rule in $add) { Write-KiraLog "set permission: $rule in $settings" }
        if (-not $DryRun) {
            Initialize-KiraDirectory $ClaudeDir
            Write-KiraText $settings $new
        }
        $changed = $true
    }

    if ($Uninstall) { Clear-KiraPermissionRecord; return }
    # The record: the expected rules kirakit inserted, now or earlier (R12).
    $record = @($expected | Where-Object { $recorded -ccontains $_ -or ($changed -and $add -ccontains $_) })
    if ($record.Count -eq 0) {
        Clear-KiraPermissionRecord
        return
    }
    $recordText = Join-KiraLine $record
    $current = if (Test-Path -LiteralPath $PermissionsPath) { Read-KiraText $PermissionsPath } else { $null }
    if ($current -cne $recordText) {
        Write-KiraLog "save permission record: $PermissionsPath"
        if (-not $DryRun) {
            Initialize-KiraDirectory $ClaudeDir
            Write-KiraText $PermissionsPath $recordText
        }
    }
}

function Install-KiraClaude([string]$Style, $UserProfile) {
    if (Test-Path -LiteralPath (Join-Path (Join-Path $script:Src 'claude') 'CLAUDE.md')) {
        Install-KiraBuilt 'CLAUDE.md' (Join-Path $ClaudeDir 'CLAUDE.md')
    }
    $agents = Join-Path (Join-Path $script:Src 'claude') 'agents'
    if (Test-Path -LiteralPath $agents) {
        foreach ($file in Get-ChildItem -LiteralPath $agents -Filter '*.md' -File | Sort-Object Name) {
            Install-KiraBuilt "agents/$($file.Name)" (Join-Path (Join-Path $ClaudeDir 'agents') $file.Name)
        }
    }
    $team = Join-Path $script:Src 'team'
    if (Test-Path -LiteralPath $team) {
        foreach ($file in Get-ChildItem -LiteralPath $team -Filter '*.md' -File | Sort-Object Name) {
            Install-KiraBuilt "agents/$($file.Name)" (Join-Path (Join-Path $ClaudeDir 'agents') $file.Name)
        }
    }
    # Claude Code loads every file of rules/ on its own.
    $rules = Join-Path (Join-Path $script:Src 'claude') 'rules'
    if (Test-Path -LiteralPath $rules) {
        foreach ($file in Get-ChildItem -LiteralPath $rules -Filter '*.md' -File | Sort-Object Name) {
            Install-KiraBuilt "rules/$($file.Name)" (Join-Path (Join-Path $ClaudeDir 'rules') $file.Name)
        }
    }
    # Skills are directories holding a SKILL.md, installed as a whole.
    $skills = Join-Path (Join-Path $script:Src 'claude') 'skills'
    if (Test-Path -LiteralPath $skills) {
        foreach ($dir in Get-ChildItem -LiteralPath $skills -Directory | Sort-Object Name) {
            if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'SKILL.md'))) { continue }
            Install-KiraBuilt "skills/$($dir.Name)" (Join-Path (Join-Path $ClaudeDir 'skills') $dir.Name)
        }
    }
    # Each team member's command, a skill built from team\NAME.md.
    if (Test-Path -LiteralPath $team) {
        foreach ($file in Get-ChildItem -LiteralPath $team -Filter '*.md' -File | Sort-Object Name) {
            Install-KiraBuilt "skills/$($file.BaseName)" (Join-Path (Join-Path $ClaudeDir 'skills') $file.BaseName)
        }
    }
    Install-KiraOutputStyle $Style
    Install-KiraAttribution
    Sync-KiraPermission $UserProfile
}

# Copy github\ into the target repository's .github directory. Files are always copied:
# they belong to that repository and are committed there.
function Install-KiraGithub {
    $root = $Target
    if (-not $root) {
        # Windows PowerShell 5.1 turns a native command's error output into a terminating error.
        $ErrorActionPreference = 'Continue'
        $root = & git rev-parse --show-toplevel 2>$null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0 -or -not $root) { throw '-Only github needs a Git repository: run it from one or pass -Target DIR' }
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "not a directory: $root" }
    $root = (Resolve-Path -LiteralPath $root).ProviderPath.TrimEnd('\', '/')
    Write-KiraLog "github target: $(Join-Path $root '.github')"
    $script:Mode = 'copy'
    $source = Join-Path $script:Src 'github'
    $prefix = 'github/' + (Split-Path -Leaf $root) + '/'
    foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File | Where-Object { $_.Name -ne '.gitkeep' } | Sort-Object FullName) {
        $rel = $file.FullName.Substring($source.Length + 1)
        Install-KiraFile $file.FullName (Join-Path (Join-Path $root '.github') $rel) $root $prefix
    }
}

# Merge this run's destinations into the manifest read by -Uninstall, and the backups of files
# that were there before kirakit into the list of originals; drop the files this run removed.
function Save-KiraManifest {
    if ($script:Installed.Count -eq 0 -and $script:Removed.Count -eq 0) { return }
    if ($DryRun) { Write-DryRun "record installed files in $ManifestPath"; return }
    $all = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $ManifestPath) { $all.AddRange([IO.File]::ReadAllLines($ManifestPath, $Utf8)) }
    $all.AddRange($script:Installed)
    $sorted = $all | Where-Object { $_ -and $script:Removed -notcontains $_ } | Sort-Object -Unique
    Write-KiraText $ManifestPath (Join-KiraLine @($sorted))
    if ($script:OriginalsNew.Count -gt 0) {
        $previous = if (Test-Path -LiteralPath $OriginalsPath) { Read-KiraText $OriginalsPath } else { '' }
        Write-KiraText $OriginalsPath ($previous + (Join-KiraLine $script:OriginalsNew.ToArray()))
    }
    if ($script:Removed.Count -gt 0 -and (Test-Path -LiteralPath $OriginalsPath)) {
        $kept = @([IO.File]::ReadAllLines($OriginalsPath, $Utf8) | Where-Object { $_ -and $script:Removed -notcontains $_.Split("`t")[0] })
        Write-KiraText $OriginalsPath $(if ($kept.Count -gt 0) { Join-KiraLine $kept } else { '' })
    }
}

# Remove a file kirakit installed (a symbolic link is deleted, a copy is moved to the
# backups) and restore what was there before kirakit.
function Uninstall-KiraFile([string]$Path) {
    if (Get-KiraLinkTarget $Path) {
        Write-KiraLog "remove link: $Path"
        if ($DryRun) { Write-DryRun "remove $Path" } else { (Get-Item -LiteralPath $Path -Force).Delete() }
    } elseif (Test-Path -LiteralPath $Path) {
        Backup-KiraPath -Path $Path | Out-Null
    }
    $original = $null
    if (Test-Path -LiteralPath $OriginalsPath) {
        foreach ($line in [IO.File]::ReadAllLines($OriginalsPath, $Utf8)) {
            $fields = $line.Split("`t")
            if ($fields.Count -eq 2 -and $fields[0] -eq $Path) { $original = $fields[1]; break }
        }
    }
    if ($original -and (Test-KiraPresent $original)) {
        Write-KiraLog "restore: $original -> $Path"
        if ($DryRun) { Write-DryRun "move $original to $Path" } else { Move-Item -LiteralPath $original -Destination $Path }
    }
}

# Remove what the manifest lists.
function Invoke-KiraUninstall {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "nothing to uninstall: $ManifestPath not found" }
    foreach ($path in [IO.File]::ReadAllLines($ManifestPath, $Utf8)) {
        if (-not $path) { continue }
        if ($path -match '(^|[\\/])\.\.([\\/]|$)' -or -not $path.StartsWith($ClaudeDir + $Sep)) {
            Write-KiraLog "skip: $path"
            continue
        }
        Uninstall-KiraFile $path
    }
    Write-KiraLog "remove manifest: $ManifestPath"
    if ($DryRun) {
        Write-DryRun "remove $ManifestPath and $OriginalsPath"
    } else {
        Remove-Item -LiteralPath $ManifestPath -Force
        if (Test-Path -LiteralPath $OriginalsPath) { Remove-Item -LiteralPath $OriginalsPath -Force }
    }
    # R8: only the rules kirakit added, as recorded.
    Sync-KiraPermission @{} -Uninstall
    Write-KiraLog "kept: $ProfilePath, $(Join-Path $ClaudeDir '.kirakit-backups') and the outputStyle and attribution settings"
}

# --- Main -----------------------------------------------------------------------------------

$exitCode = 0
try {
    if ($Bound.ContainsKey('CoAuthor') -and ($CoAuthor -eq '' -or -not (Test-KiraCoAuthor $CoAuthor))) {
        throw "invalid co-author: $CoAuthor (expected `"NAME <EMAIL>`")"
    }
    if ($Bound.ContainsKey('Assistant') -and ($Assistant -eq '' -or -not (Test-KiraCoAuthor $Assistant))) {
        throw "invalid assistant: $Assistant (expected `"NAME <EMAIL>`")"
    }
    if ($AssistantSigningKey -match "`n") { throw "invalid signing key path: $AssistantSigningKey" }
    if (-not (Test-KiraGithub $AssistantGithub)) { throw "invalid GitHub login: $AssistantGithub" }
    if (-not (Test-KiraGithub $AnalystGithub)) { throw "invalid GitHub login: $AnalystGithub" }
    if ($Bound.ContainsKey('Coder') -and ($Coder -eq '' -or -not (Test-KiraCoAuthor $Coder))) {
        throw "invalid coder: $Coder (expected `"NAME <EMAIL>`")"
    }
    if ($CoderSigningKey -match "`n") { throw "invalid signing key path: $CoderSigningKey" }
    if (-not (Test-KiraGithub $CoderGithub)) { throw "invalid GitHub login: $CoderGithub" }
    foreach ($personaName in @($Persona) + @($DefaultStyle | Where-Object { $_ })) {
        if ($personaName -notmatch '^[A-Za-z0-9_-]+$') { throw "invalid persona name: $personaName" }
    }
    if ($DryRun) { Write-KiraLog 'dry run: nothing will be changed' }

    if ($Uninstall) {
        Invoke-KiraUninstall
    } else {
        # Use the clone this script lives in, if any; otherwise fetch the repository.
        if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot 'personas') '_core.md'))) {
            $script:Src = $PSScriptRoot
            $onWindows = $env:OS -eq 'Windows_NT'
            $script:Mode = if ($Link) { 'link' } elseif ($Copy -or $onWindows) { 'copy' } else { 'link' }
        } else {
            if ($Link) { throw '-Link needs a local clone: run get-kira.ps1 from the repository' }
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required' }
            $repoDir = Join-Path (Get-KiraWorkDir) 'repo'
            $ref = Get-KiraRef
            Write-KiraLog "fetching $Repo ($ref)"
            # An empty repository, a shallow fetch and a checkout of FETCH_HEAD: unlike a
            # shallow clone, they print no detached HEAD advice and no "is not a commit"
            # warning for an annotated tag, while git's errors are still shown.
            # Windows PowerShell 5.1 turns a native command's error output into a terminating
            # error when it is redirected: keep git's message, then throw kirakit's own.
            $ErrorActionPreference = 'Continue'
            & git init --quiet -- $repoDir
            if ($LASTEXITCODE -eq 0) { & git -C $repoDir fetch --quiet --depth 1 -- $Repo $ref }
            if ($LASTEXITCODE -eq 0) { & git -C $repoDir -c advice.detachedHead=false checkout --quiet FETCH_HEAD }
            $fetched = $LASTEXITCODE -eq 0
            $ErrorActionPreference = 'Stop'
            if (-not $fetched) { throw "could not fetch $Repo" }
            $script:Src = $repoDir
            $script:Mode = 'copy'
        }
        foreach ($personaName in @($Persona) + @($DefaultStyle | Where-Object { $_ })) {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $script:Src 'personas') "$personaName.md"))) { throw "unknown persona: $personaName" }
        }
        Write-KiraLog "source: $($script:Src) ($($script:Mode) mode)"

        if ($Only -eq 'github') {
            Install-KiraGithub
        } else {
            Write-KiraLog "target: $ClaudeDir"
            $userProfile = Get-KiraProfile
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $script:Src 'personas') "$($userProfile.style).md"))) {
                throw "unknown default style: $($userProfile.style)"
            }
            $shownName = if ($userProfile.name) { $userProfile.name } else { '(no name)' }
            $shownAssistant = if ($userProfile.assistant) { $userProfile.assistant } else { 'none' }
            Write-KiraLog "profile: $shownName, $($userProfile.gender), language $($userProfile.language), assistant $shownAssistant, co-author trailers $($userProfile.co_author_trailer), analyst $($userProfile.analyst)$(if ($userProfile.analyst_github) { " ($($userProfile.analyst_github))" }), coder $(if ($userProfile.coder) { $userProfile.coder } else { 'none' }), style $($userProfile.style)"
            Test-KiraSigningKey 'the assistant' $userProfile.assistant_signing_key
            Test-KiraSigningKey 'the coder' $userProfile.coder_signing_key
            Build-KiraOutput $userProfile
            if (-not $Only -or $Only -eq 'styles') { Install-KiraStyle }
            if (-not $Only -or $Only -eq 'claude') { Install-KiraClaude $userProfile.style $userProfile }
            if (-not $Only -or $Only -eq 'launchers') {
                Write-KiraLog 'notice: the launchers (assistant, analyst, team) are not supported on Windows; none is installed'
            }
            Save-KiraManifest
        }
    }
    Write-KiraLog 'done'
} catch {
    [Console]::Error.WriteLine("kirakit: error: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

# Only exit when run as a file: exiting from a script block would close the caller's session.
if ($PSCommandPath) { exit $exitCode }
