# TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
# Installer scripts: Copyright (c) 2026 TheAstroMirth.
# Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
#
# Shared helpers for the TypingIndicators Windows installer and uninstaller.
# Dot-sourced by install.ps1 and uninstall.ps1. Works on Windows PowerShell 5.1 and PowerShell 7.

$PluginName  = 'TypingIndicators'
$PluginFiles = @('index.tsx', 'style.css')

$VencordDocs       = 'https://docs.vencord.dev/installing/'
$VencordPluginDocs = 'https://docs.vencord.dev/installing/custom-plugins/'
$EquicordDocs      = 'https://github.com/Equicord/Equicord#installing-equicord-devbuild'

# Set while the script is being stopped on purpose, and an optional clean-up
# script block that runs before the script exits.
$script:Stopping = $false
$script:OnStop   = $null

# Working folder used by Restore-Backup while a restore is in progress.
$script:RestoreStage = $null

function Write-Step($m) { Write-Host ''; Write-Host "== $m ==" -ForegroundColor White }
function Write-Info($m) { Write-Host "   $m" }
function Write-Ok($m)   { Write-Host ' + ' -ForegroundColor Green -NoNewline; Write-Host $m }
function Write-Warn($m) { Write-Host ' ! ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Write-Fail($m) { Write-Host ' x ' -ForegroundColor Red -NoNewline; Write-Host $m }

function Stop-Script($m) {
    Write-Fail $m
    $script:Stopping = $true
    if ($script:OnStop) { & $script:OnStop }
    Write-Host ''
    Write-Host "$ScriptTitle stopped. Nothing else was changed." -ForegroundColor Red
    exit 1
}

function Test-Cmd($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# Ask-YesNo 'Question' $true/$false(default)
function Ask-YesNo($prompt, $default) {
    if ($Yes) { return $default }
    if ($default) { $hint = '[Y/n]' } else { $hint = '[y/N]' }
    $reply = Read-Host "   $prompt $hint"
    if ($reply -match '^\s*(y|yes)\s*$') { return $true }
    if ($reply -match '^\s*(n|no)\s*$')  { return $false }
    return $default
}

function Assert-Windows {
    if ($env:OS -ne 'Windows_NT' -and -not $env:TI_ALLOW_NON_WINDOWS) {
        Stop-Script 'This script is for Windows 10/11. On macOS use installers/macos/install.command.'
    }
}

function Get-BackupRoot {
    if ($env:TI_BACKUP_ROOT) { return $env:TI_BACKUP_ROOT }
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $HOME }
    return (Join-Path (Join-Path $base 'TypingIndicators') 'backups')
}

# ------------------------------------------------------------------ client

function Get-ClientLabel($client) {
    if ($client -eq 'equicord') { return 'Equicord' }
    return 'Vencord'
}

function Get-ClientDocs($client) {
    if ($client -eq 'equicord') { return $EquicordDocs }
    return $VencordDocs
}

# Returns 'vencord' or 'equicord', or stops the script.
function Select-Client {
    if ($Client) {
        $c = $Client.Trim().ToLower()
        if ($c -ne 'vencord' -and $c -ne 'equicord') {
            Stop-Script "Unknown client '$Client'. Use -Client vencord or -Client equicord."
        }
    } elseif ($Yes) {
        Stop-Script 'With -Yes you must also pass -Client vencord or -Client equicord.'
    } else {
        Write-Info 'Which client do you use?'
        Write-Info '  [1] Vencord'
        Write-Info '  [2] Equicord'
        $c = $null
        while (-not $c) {
            $reply = Read-Host '   Choose 1 or 2 (q to quit)'
            if ($null -eq $reply) { Stop-Script 'No client selected.' }
            $r = $reply.Trim().ToLower()
            if ($r -eq '1' -or $r -eq 'vencord') { $c = 'vencord' }
            elseif ($r -eq '2' -or $r -eq 'equicord') { $c = 'equicord' }
            elseif ($r -eq 'q' -or $r -eq 'quit') { Stop-Script 'No client selected.' }
        }
    }
    Write-Ok "Client: $(Get-ClientLabel $c)"
    return $c
}

# ---------------------------------------------------------------- checkouts

# Returns 'vencord' or 'equicord' when the folder looks like the root of a source
# folder of that project, otherwise $null. A package.json alone is not enough.
function Get-CheckoutClient($dir) {
    if (-not $dir) { return $null }
    $pkg = Join-Path $dir 'package.json'
    if (-not (Test-Path -LiteralPath $pkg -PathType Leaf)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $dir 'src') 'plugins') -PathType Container)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $dir 'scripts') 'build') 'build.mjs') -PathType Leaf)) { return $null }
    try {
        $name = (Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).name
    } catch {
        return $null
    }
    if ($name -ceq 'vencord') { return 'vencord' }
    if ($name -ceq 'equicord') {
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $dir 'src') 'equicordplugins') -PathType Container)) { return $null }
        return 'equicord'
    }
    return $null
}

# Accepts the repository root, its src folder, src\userplugins (or a folder
# below that) and returns the repository root.
function Find-CheckoutRoot($dir) {
    if (-not $dir) { return $null }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $cur = (Resolve-Path -LiteralPath $dir).ProviderPath
    for ($i = 0; $i -lt 4 -and $cur; $i++) {
        if (Get-CheckoutClient $cur) { return $cur.TrimEnd('\', '/') }
        $parent = Split-Path -Path $cur -Parent
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    return $null
}

function Format-UserPath($p) {
    if (-not $p) { return '' }
    $p = $p.Trim().Trim('"').Trim("'").Trim()
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if ($p -eq '~') { $p = $HOME }
    elseif ($p.StartsWith('~\') -or $p.StartsWith('~/')) { $p = Join-Path $HOME $p.Substring(2) }
    return $p
}

# Checks that $path is a usable source folder for $client.
# Returns @{ Code; Root; Client; Reason } where Code is
# 0 = usable, 1 = not a source folder, 2 = the other client, 3 = not a Git checkout.
function Test-Checkout($path, $client) {
    $result = @{ Code = 1; Root = $null; Client = $null; Reason = '' }
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
        $result.Reason = "That folder does not exist: $path"
        return $result
    }
    $root = Find-CheckoutRoot $path
    if (-not $root) {
        $result.Reason = "That is not a Vencord or Equicord source folder: $path"
        return $result
    }
    $result.Root = $root
    $result.Client = Get-CheckoutClient $root
    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        $result.Code = 3
        $result.Reason = "$root is not a Git checkout (it looks like a downloaded zip)."
        return $result
    }
    if ($result.Client -ne $client) {
        $result.Code = 2
        $result.Reason = "That is a source folder of the other client, not $(Get-ClientLabel $client): $root"
        return $result
    }
    $result.Code = 0
    return $result
}

function Show-SourceNeeded($client) {
    $label = Get-ClientLabel $client
    Write-Host ''
    Write-Warn "A $label source folder is required."
    Write-Info "Custom plugins cannot be added to the normal installer version of $label."
    Write-Info 'They are built from the source code, so you need a source folder'
    Write-Info "(a 'git clone' of $label) on this PC first."
    Write-Info "This installer does not download, clone or install $label for you."
    Write-Host ''
    Write-Info 'Official guide:'
    if ($client -eq 'equicord') {
        Write-Info "  $EquicordDocs"
    } else {
        Write-Info "  $VencordDocs"
        Write-Info "  $VencordPluginDocs"
    }
    Write-Info 'Set it up, then run this again.'
}

function Show-ExpectedFolder {
    Write-Info 'A source folder contains package.json, a src\plugins folder and'
    Write-Info "scripts\build\build.mjs. You can give the folder itself, its 'src' folder"
    Write-Info "or its 'src\userplugins' folder."
}

# Returns @{ Repo; Client } (the client can change if the user agrees) or stops the script.
function Select-Checkout($client) {
    $label = Get-ClientLabel $client

    if ($Source) {
        $r = Test-Checkout (Format-UserPath $Source) $client
        if ($r.Code -ne 0) {
            Write-Fail $r.Reason
            if ($r.Code -eq 1) { Show-ExpectedFolder }
            if ($r.Code -eq 3) { Write-Info "The source folder must be a 'git clone', see $(Get-ClientDocs $client)" }
            Stop-Script 'The folder passed with -Source cannot be used.'
        }
        Write-Ok "Using $label source folder: $($r.Root)"
        return @{ Repo = $r.Root; Client = $client }
    }

    if ($Yes) { Stop-Script 'With -Yes you must also pass -Source "C:\path\to\folder".' }

    if (-not (Ask-YesNo "Do you already have a $label source folder (a git clone) on this PC?" $true)) {
        Show-SourceNeeded $client
        Stop-Script 'No source folder available.'
    }

    while ($true) {
        Write-Host ''
        Write-Info "Type or paste the path of your $label source folder and press Enter."
        Write-Info 'Or press Enter on an empty line to open a folder picker. Type q to quit.'
        $reply = Read-Host '   Folder'
        if ($null -eq $reply) { Stop-Script 'No source folder selected.' }
        if ($reply -match '^\s*(q|quit)\s*$') { Stop-Script 'No source folder selected.' }
        $picked = $null
        if (-not $reply.Trim()) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = 'Select your Vencord or Equicord source folder'
                $dlg.ShowNewFolderButton = $false
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $picked = $dlg.SelectedPath }
            } catch {
                Write-Warn 'Could not open a folder picker here. Please type the path instead.'
                continue
            }
            if (-not $picked) { Write-Warn 'No folder selected.'; continue }
        } else {
            $picked = Format-UserPath $reply
        }

        $r = Test-Checkout $picked $client
        if ($r.Code -eq 0) {
            Write-Ok "Using $label source folder: $($r.Root)"
            return @{ Repo = $r.Root; Client = $client }
        }
        Write-Warn $r.Reason
        if ($r.Code -eq 2) {
            $other = Get-ClientLabel $r.Client
            if (Ask-YesNo "That folder is $other. Use it and continue with $other instead?" $true) {
                Write-Ok "Using $other source folder: $($r.Root)"
                return @{ Repo = $r.Root; Client = $r.Client }
            }
            Write-Info 'Choose another folder.'
        } elseif ($r.Code -eq 3) {
            Write-Info "The source folder must be a 'git clone', see $(Get-ClientDocs $client)"
            Write-Info 'Choose another folder.'
        } else {
            Show-ExpectedFolder
        }
    }
}

# ------------------------------------------------------------ prerequisites

# Returns $true when PowerShell, Git, Node.js and pnpm are usable.
function Test-Tools {
    $missing = $false

    $psv = $PSVersionTable.PSVersion
    if ($psv.Major -lt 5 -or ($psv.Major -eq 5 -and $psv.Minor -lt 1)) {
        Write-Fail "PowerShell $psv is too old. PowerShell 5.1 or newer is needed."
        Write-Info 'Windows 10 and 11 include it. Install pending Windows updates and try again.'
        $missing = $true
    } else {
        Write-Ok "PowerShell found ($psv)"
    }

    if (Test-Cmd 'git') {
        $v = [string](& git --version)
        Write-Ok "Git found ($($v -replace '^git version ', ''))"
    } else {
        Write-Fail 'Git was not found.'
        Write-Info 'Get it from https://git-scm.com/download/win   (or: winget install Git.Git)'
        $missing = $true
    }

    if (Test-Cmd 'node') {
        Write-Ok "Node.js found ($([string](& node -v)))"
    } else {
        Write-Fail 'Node.js was not found.'
        Write-Info 'Get the LTS version from https://nodejs.org/   (or: winget install OpenJS.NodeJS.LTS)'
        $missing = $true
    }

    if (Test-Cmd 'pnpm') {
        Write-Ok "pnpm found ($([string](& pnpm --version)))"
    } else {
        Write-Fail 'pnpm was not found.'
        Write-Info 'Install it with:  npm install -g pnpm'
        $missing = $true
    }

    if ($missing) {
        Write-Info 'Nothing is installed for you. Install what is missing, open a new'
        Write-Info 'window and run this again.'
        return $false
    }
    return $true
}

# Compares the installed Node.js with what the source folder asks for.
function Test-NodeVersion($repo, $label) {
    $have = 0
    $want = 0
    $v = ([string](& node -v)) -replace '^v', ''
    [void][int]::TryParse(($v -split '\.')[0], [ref]$have)
    try {
        $eng = (Get-Content -LiteralPath (Join-Path $repo 'package.json') -Raw | ConvertFrom-Json).engines.node
        if ($eng -match '(\d+)') { $want = [int]$Matches[1] }
    } catch { $want = 0 }
    if ($want -gt 0 -and $have -gt 0 -and $have -lt $want) {
        Write-Fail "Node.js v$v is too old. This $label source folder needs Node.js $want or newer."
        Write-Info 'Get the current LTS from https://nodejs.org/'
        return $false
    }
    return $true
}

# Returns $true when dependencies are ready for a build.
function Confirm-Dependencies($repo, $label) {
    if (Test-Path -LiteralPath (Join-Path $repo 'node_modules') -PathType Container) {
        Write-Ok "$label dependencies are installed (node_modules)"
        return $true
    }
    Write-Warn "$label dependencies are not installed yet (no node_modules folder)."
    Write-Info 'They are needed to build. The step for this is: pnpm install --frozen-lockfile'
    if (Ask-YesNo "Run it now in $repo?" $true) {
        Push-Location -LiteralPath $repo
        try {
            & pnpm install --frozen-lockfile | Out-Host
            $rc = $LASTEXITCODE
        } finally { Pop-Location }
        if ($rc -ne 0) {
            Write-Fail "pnpm install failed (exit code $rc). See the output above."
            return $false
        }
        Write-Ok 'Dependencies installed'
        return $true
    }
    Write-Info 'Skipped. Without the dependencies the build cannot run.'
    return $false
}

# Returns $true only if the build really succeeded.
function Invoke-Build($repo) {
    Write-Info "Running: pnpm build   (in $repo)"
    Write-Host ''
    Push-Location -LiteralPath $repo
    try {
        & pnpm build | Out-Host
        $rc = $LASTEXITCODE
    } finally { Pop-Location }
    Write-Host ''
    if ($rc -ne 0) {
        Write-Fail "The build FAILED (pnpm build exit code $rc). See the output above."
        return $false
    }
    Write-Ok 'Build finished'
    return $true
}

# ------------------------------------------------------------ small helpers

# True when something exists at $path, including a link whose target is gone.
function Test-Exists($path) {
    if (-not $path) { return $false }
    if (Test-Path -LiteralPath $path) { return $true }
    try {
        $null = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# True for a symbolic link or junction. Other reparse points (for example
# cloud-storage placeholders) are ordinary files and folders for our purposes.
function Test-IsLink($path) {
    try {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    } catch {
        return $false
    }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
    $type = [string]$item.LinkType
    return ($type -eq 'SymbolicLink' -or $type -eq 'Junction')
}

# Removes one entry. For a link only the link is removed, never its target.
function Remove-Entry($path) {
    if (-not $path) { return }
    if (-not (Test-Exists $path)) { return }
    if (Test-IsLink $path) {
        if (Test-Path -LiteralPath $path -PathType Container) { [System.IO.Directory]::Delete($path, $false) }
        else { [System.IO.File]::Delete($path) }
    } else {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

# Renames a file, folder or link inside the same drive. This is one step for
# the file system, so the entry is never half moved.
function Move-Entry($from, $to) {
    if (Test-Path -LiteralPath $from -PathType Container) { [System.IO.Directory]::Move($from, $to) }
    else { [System.IO.File]::Move($from, $to) }
}

# Working names inside src\userplugins: .TypingIndicators.<kind>.<process id>
# The Vencord and Equicord builds ignore entries that start with a dot.
function Get-StagePath($userPlugins, $kind) {
    return (Join-Path $userPlugins ".$PluginName.$kind.$PID")
}

# Returns the full path of an existing TypingIndicators entry in src\userplugins
# (whatever its letter case), or $null.
function Find-ExistingPlugin($userPlugins) {
    if (-not (Test-Path -LiteralPath $userPlugins -PathType Container)) { return $null }
    $items = @(Get-ChildItem -LiteralPath $userPlugins -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if ($item.Name -ieq $PluginName) { return $item.FullName }
    }
    return $null
}

# Returns "relative/path|SHA256" lines for every file below $dir, sorted.
function Get-TreeHashes($dir) {
    $base = (Resolve-Path -LiteralPath $dir).ProviderPath.TrimEnd('\', '/')
    $lines = @()
    $files = @(Get-ChildItem -LiteralPath $base -Recurse -Force -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/') -replace '\\', '/'
        $lines += ($rel + '|' + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash)
    }
    return @($lines | Sort-Object)
}

function Test-SameTree($a, $b) {
    $ha = @(Get-TreeHashes $a) -join "`n"
    $hb = @(Get-TreeHashes $b) -join "`n"
    return ($ha -ceq $hb)
}

# True when $dir contains a symbolic link or junction anywhere below it.
function Test-HasLinks($dir) {
    $items = @(Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $type = [string]$item.LinkType
            if ($type -eq 'SymbolicLink' -or $type -eq 'Junction') { return $true }
        }
    }
    return $false
}

# Tells the user about working folders left behind by a run that was closed or
# killed before it could clean up. Nothing is deleted here.
# Returns the previous plugin folder when exactly one was left, otherwise $null.
function Show-Leftovers($userPlugins, $label) {
    if (-not (Test-Path -LiteralPath $userPlugins -PathType Container)) { return $null }
    $old = @()
    $items = @(Get-ChildItem -LiteralPath $userPlugins -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        if ($item.Name -like ".$PluginName.old.*") {
            $old += $item.FullName
            Write-Warn 'An earlier run was interrupted. It left the PREVIOUS plugin folder here:'
            Write-Info "  $($item.FullName)"
            Write-Info "To get it back by hand: remove '$PluginName' next to it (if there is one)"
            Write-Info "and rename this folder to '$PluginName'. Delete it if you do not need it."
        } elseif ($item.Name -like ".$PluginName.*.*") {
            Write-Warn 'An earlier run was interrupted. It left an incomplete working copy here:'
            Write-Info "  $($item.FullName)"
            Write-Info "It is not used by $label and can be deleted."
        }
    }
    if ($old.Count -eq 1) { return $old[0] }
    return $null
}

# ----------------------------------------------------------------- backups

function Test-SamePath($a, $b) {
    if (-not $a -or -not $b) { return $false }
    return ($a.TrimEnd('\', '/') -ieq $b.TrimEnd('\', '/'))
}

# Copies $existing to a new timestamped folder. Returns the backup folder, or $null
# on failure. Never reuses or overwrites an existing backup folder.
# backup-info.txt is written last, so a backup that was cut short is never
# listed or offered for restoring.
function New-PluginBackup($existing, $client, $repo) {
    $root = Get-BackupRoot
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $dir = Join-Path $root $stamp
    $n = 1
    while (Test-Exists $dir) {
        $n++
        if ($n -gt 50) { return $null }
        $dir = Join-Path $root "$stamp-$n"
    }
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $target = Join-Path $dir $PluginName
        $kind = 'folder'
        $isDir = Test-Path -LiteralPath $existing -PathType Container
        # For a link this copies the files it points to, so the backup holds real files.
        Copy-Item -LiteralPath $existing -Destination $target -Recurse -Force
        if (Test-IsLink $existing) { $kind = 'link' } elseif (-not $isDir) { $kind = 'file' }
        if ($isDir) {
            if (-not (Test-SameTree $existing $target)) { return $null }
            $manifest = @(Get-TreeHashes $target)
            Set-Content -LiteralPath (Join-Path $dir 'backup-manifest.txt') -Value $manifest -Encoding UTF8
        } else {
            $a = (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash
            $b = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if ($a -ne $b) { return $null }
        }
        $info = @("client=$client", "source=$repo", "original=$existing", "created=$stamp", "kind=$kind")
        Set-Content -LiteralPath (Join-Path $dir 'backup-info.txt') -Value $info -Encoding UTF8
    } catch {
        Write-Fail $_.Exception.Message
        Write-Info "An unfinished backup folder may be left at: $dir"
        return $null
    }
    return $dir
}

function Get-BackupField($dir, $name) {
    $file = Join-Path $dir 'backup-info.txt'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    foreach ($line in @(Get-Content -LiteralPath $file)) {
        if ($line -and $line.StartsWith("$name=")) { return $line.Substring($name.Length + 1) }
    }
    return ''
}

# True when the backup was taken from exactly this source folder and client.
function Test-BackupIsOurs($dir, $client, $repo) {
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'backup-info.txt') -PathType Leaf)) { return $false }
    if ((Get-BackupField $dir 'client') -ne $client) { return $false }
    if (-not (Test-SamePath (Get-BackupField $dir 'source') $repo)) { return $false }
    return (Test-Exists (Join-Path $dir $PluginName))
}

function Get-BackupFolders {
    $root = Get-BackupRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name -Descending)
}

# Returns the backups taken from $repo for $client, newest first.
function Get-Backups($client, $repo) {
    $found = @()
    foreach ($d in @(Get-BackupFolders)) {
        if (Test-BackupIsOurs $d.FullName $client $repo) { $found += $d.FullName }
    }
    return $found
}

# Returns how many complete backups belong to another source folder or client.
function Get-OtherBackupCount($client, $repo) {
    $n = 0
    foreach ($d in @(Get-BackupFolders)) {
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'backup-info.txt') -PathType Leaf)) { continue }
        if (-not (Test-BackupIsOurs $d.FullName $client $repo)) { $n++ }
    }
    return $n
}

# Checks that a backup can be restored into $repo.
# Returns @{ Ok; Problem; Note }.
function Test-Backup($dir, $client, $repo) {
    $result = @{ Ok = $false; Problem = ''; Note = '' }
    $payload = Join-Path $dir $PluginName
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'backup-info.txt') -PathType Leaf)) {
        $result.Problem = 'it has no backup-info.txt, so it is incomplete'
        return $result
    }
    if ((Get-BackupField $dir 'client') -ne $client) {
        $result.Problem = 'it was made for another client'
        return $result
    }
    $source = Get-BackupField $dir 'source'
    if (-not (Test-SamePath $source $repo)) {
        $result.Problem = "it was taken from another source folder ($source)"
        return $result
    }
    if (-not (Test-Exists $payload)) {
        $result.Problem = "it does not hold a $PluginName folder"
        return $result
    }
    if (Test-IsLink $payload) {
        $result.Problem = 'it holds a link, not plugin files. Recreate the link by hand if you still want it'
        return $result
    }
    if (-not (Test-Path -LiteralPath $payload -PathType Container)) {
        $result.Problem = "it does not hold a $PluginName folder"
        return $result
    }
    if (Test-HasLinks $payload) {
        $result.Problem = 'it contains links to other places'
        return $result
    }
    $hasIndex = $false
    foreach ($entry in 'index.tsx', 'index.ts') {
        $p = Join-Path $payload $entry
        if ((Test-Path -LiteralPath $p -PathType Leaf) -and ((Get-Item -LiteralPath $p -Force).Length -gt 0)) { $hasIndex = $true }
    }
    if (-not $hasIndex) {
        $result.Problem = 'it has no index.tsx, so it is not a usable plugin folder'
        return $result
    }
    $manifestFile = Join-Path $dir 'backup-manifest.txt'
    if (Test-Path -LiteralPath $manifestFile -PathType Leaf) {
        $recorded = @(Get-Content -LiteralPath $manifestFile | Where-Object { $_ }) -join "`n"
        $actual = @(Get-TreeHashes $payload) -join "`n"
        if ($recorded -cne $actual) {
            $result.Problem = 'its files no longer match the checksums recorded when it was made'
            return $result
        }
    } else {
        $result.Note = 'no checksum list was recorded for it, so only its structure was checked'
    }
    $result.Ok = $true
    return $result
}

# Copies the backup to a working folder, checks the copy, moves it into place in
# one step and checks it again. Returns '' on success, otherwise what went wrong.
# $script:RestoreStage names the working folder while it exists.
function Restore-Backup($dir, $userPlugins) {
    $payload = Join-Path $dir $PluginName
    $dest = Join-Path $userPlugins $PluginName
    if (Find-ExistingPlugin $userPlugins) { return "a $PluginName folder is already in place" }
    try {
        New-Item -ItemType Directory -Path $userPlugins -Force | Out-Null
        $stage = Get-StagePath $userPlugins 'restore'
        if (Test-Exists $stage) { return "a working folder is in the way: $stage" }
        $script:RestoreStage = $stage
        Copy-Item -LiteralPath $payload -Destination $stage -Recurse -Force
        if (-not (Test-SameTree $payload $stage)) {
            Remove-Entry $stage
            $script:RestoreStage = $null
            return 'the copy did not match the backup'
        }
        Move-Entry $stage $dest
        $script:RestoreStage = $null
    } catch {
        $message = $_.Exception.Message
        try { if ($script:RestoreStage) { Remove-Entry $script:RestoreStage } } catch { }
        $script:RestoreStage = $null
        return "the copy could not be made or moved into place ($message)"
    }
    try {
        $ok = Test-SameTree $payload $dest
        $manifestFile = Join-Path $dir 'backup-manifest.txt'
        if ($ok -and (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
            $recorded = @(Get-Content -LiteralPath $manifestFile | Where-Object { $_ }) -join "`n"
            $actual = @(Get-TreeHashes $dest) -join "`n"
            $ok = ($recorded -ceq $actual)
        }
        if (-not $ok) {
            Remove-Entry $dest
            return 'the restored files did not match the backup and were removed again'
        }
    } catch {
        return "the restored files could not be checked ($($_.Exception.Message))"
    }
    return ''
}
