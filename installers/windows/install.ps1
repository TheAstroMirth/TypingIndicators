# TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
# Installer scripts: Copyright (c) 2026 TheAstroMirth.
# Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
#
# TypingIndicators installer for Windows 10/11.
# Copies the plugin into an existing Vencord or Equicord source folder and builds it.
# It never downloads, clones or installs Vencord or Equicord, and needs no administrator rights.
#
# How the plugin folder is changed:
#   1. The new folder is prepared and checked under a working name.
#   2. An existing folder is moved aside, the new one is moved into place.
#   3. The folder moved aside is kept until the build result is known, so the
#      previous installation can be put back exactly as it was.
# If anything fails or the run is interrupted during 1 or 2, the previous
# installation is put back automatically.
#
# Options:
#   -Client NAME    vencord or equicord (skips the question)
#   -Source "PATH"  Your Vencord/Equicord source folder (skips the question)
#   -Yes            Do not ask questions, use the default answers
#                   (needs -Client and -Source; never runs 'pnpm inject'
#                   and never rolls back on its own)
#   -NoBuild        Copy the plugin but do not run 'pnpm build'

param(
    [string]$Client = '',
    [string]$Source = '',
    [switch]$Yes,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$ScriptTitle = 'TypingIndicators install'
$CommonFile = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $CommonFile -PathType Leaf)) {
    Write-Host 'Cannot find common.ps1 next to install.ps1. Keep the project folder together.' -ForegroundColor Red
    exit 1
}
. $CommonFile

$PluginSrc = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') '..') $PluginName

$Copied   = 'no'    # no | yes | already | rolledback
$Built    = 'no'    # no | yes | skipped | failed | nodeps
$Injected = 'no'    # no | yes | skipped | failed
$Rebuilt  = ''      # after a rollback: yes | failed | no
$Backup   = $null
$Repo     = $null
$Label    = ''
$UserPlugins = $null
$Dest     = $null
$Existing = $null
$Mode     = 'fresh' # fresh | update | replace | same
$ExitCode = 1

# State of the change to the plugin folder. Written by the functions below.
$script:Phase     = 'idle'   # idle | staging | swapping | installed
$script:Stage     = $null    # new folder being prepared
$script:Aside     = $null    # previous folder, moved aside
$script:AsideOrig = $null    # where the previous folder came from
$script:Completed = $false

function Get-PackageHash($f) {
    return (Get-FileHash -LiteralPath (Join-Path $PluginSrc $f) -Algorithm SHA256).Hash
}

# Checks that a folder holds both plugin files, byte for byte, with exact names.
function Test-PluginDir($dir) {
    foreach ($f in $PluginFiles) {
        $p = Join-Path $dir $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne (Get-PackageHash $f)) { return $false }
        $exact = @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -ceq $f })
        if ($exact.Count -ne 1) { return $false }
    }
    return $true
}

function Test-SameAsPackage($dir) {
    if (-not $dir) { return $false }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    if (Test-IsLink $dir) { return $false }
    if ((Split-Path -Path $dir -Leaf) -cne $PluginName) { return $false }
    return (Test-PluginDir $dir)
}

# Hash lines of every file in a folder except the two plugin files at its top level.
function Get-OtherFileHashes($dir) {
    $lines = @()
    foreach ($line in @(Get-TreeHashes $dir)) {
        $name = ($line -split '\|')[0]
        if ($PluginFiles -contains $name) { continue }
        $lines += $line
    }
    return $lines
}

# Puts the previous installation back after a swap that did not complete.
# Returns $true when src\userplugins is as it was before this run.
function Undo-Swap {
    $aside = $script:Aside
    if (-not $aside -or -not (Test-Exists $aside)) { return $true }
    $orig = $script:AsideOrig
    $script:Aside = $null
    try {
        # The previous folder is safe in $aside, so anything at $Dest is the new copy.
        if (Test-Exists $Dest) { Remove-Entry $Dest }
        if (Test-Exists $orig) { throw 'something is in the way' }
        Move-Entry $aside $orig
        Write-Ok "Your previous $PluginName folder was put back: $orig"
        return $true
    } catch {
        Write-Fail "Your previous $PluginName folder could not be put back automatically."
        Write-Info "It is safe here:  $aside"
        Write-Info "To restore it, rename that folder to '$PluginName'."
        if ($Backup) { Write-Info "A second copy is in the backup: $(Join-Path $Backup $PluginName)" }
        return $false
    }
}

# Brings src\userplugins back to a consistent state, whatever step was reached.
function Invoke-Recover {
    try {
        if ($script:Stage -and (Test-Exists $script:Stage)) { Remove-Entry $script:Stage }
    } catch { }
    $script:Stage = $null
    if ($script:Phase -eq 'swapping') {
        [void](Undo-Swap)
        $script:Phase = 'idle'
    }
}

# install: returns '' when $Dest holds the new plugin, otherwise what went wrong.
# On any failure nothing is left half done: the caller runs Invoke-Recover,
# which puts the previous folder back.
function Install-Plugin {
    try {
        New-Item -ItemType Directory -Path $UserPlugins -Force | Out-Null

        # 1. Prepare and check the new folder under a working name.
        $script:Phase = 'staging'
        $stage = Get-StagePath $UserPlugins 'new'
        if (Test-Exists $stage) { return "a working folder is in the way: $stage" }
        $script:Stage = $stage
        if ($Mode -eq 'update') {
            Copy-Item -LiteralPath $Existing -Destination $stage -Recurse -Force
        } else {
            New-Item -ItemType Directory -Path $stage | Out-Null
        }
        foreach ($f in $PluginFiles) {
            $target = Join-Path $stage $f
            # remove first, so the new file gets the exact name and letter case
            if (Test-Exists $target) { Remove-Item -LiteralPath $target -Force }
            Copy-Item -LiteralPath (Join-Path $PluginSrc $f) -Destination $target -Force
        }
        if (-not (Test-PluginDir $stage)) { return 'the copied files did not match the originals' }
        if ($Mode -eq 'update') {
            # every other file of the existing folder must have come along unchanged
            $before = @(Get-OtherFileHashes $Existing) -join "`n"
            $after  = @(Get-OtherFileHashes $stage) -join "`n"
            if ($before -cne $after) { return 'the other files of the existing folder could not be carried over' }
        }

        # 2. Swap: previous folder aside, new folder into place.
        $script:Phase = 'swapping'
        if ($Existing) {
            $aside = Get-StagePath $UserPlugins 'old'
            if (Test-Exists $aside) { return "a working folder is in the way: $aside" }
            Move-Entry $Existing $aside
            $script:Aside = $aside
            $script:AsideOrig = $Existing
        }
        Move-Entry $stage $Dest
        $script:Stage = $null
        if (-not (Test-PluginDir $Dest)) { return 'the installed files did not match the originals' }
        $now = Find-ExistingPlugin $UserPlugins
        if (-not $now -or (Split-Path -Path $now -Leaf) -cne $PluginName) {
            return 'the plugin folder did not end up with the right name'
        }
        $script:Phase = 'installed'
        return ''
    } catch {
        return $_.Exception.Message
    }
}

# Drops the copy that was moved aside. A checked backup of it exists.
function Remove-Aside {
    $aside = $script:Aside
    $script:Aside = $null
    if (-not $aside -or -not (Test-Exists $aside)) { return }
    try {
        Remove-Entry $aside
    } catch {
        Write-Warn "Could not remove the working copy $aside (it is not used, you can delete it)"
    }
}

# Undoes this run's change to the plugin folder. Returns $true when done.
function Undo-Install {
    if ($Mode -eq 'update' -or $Mode -eq 'replace') {
        if (-not $script:Aside -or -not (Test-Exists $script:Aside)) {
            Write-Fail 'The previous folder is no longer in the source folder.'
            Write-Info "Restore it from the backup with uninstall.bat: $Backup"
            return $false
        }
        if (-not (Undo-Swap)) { return $false }
    } elseif ($Mode -eq 'fresh') {
        # Only remove what this run put there, and only if it is still ours.
        if (-not (Test-SameAsPackage $Dest)) {
            Write-Fail "$Dest has changed since it was copied, so it was left alone."
            return $false
        }
        try { Remove-Entry $Dest } catch { }
        if (Test-Exists $Dest) {
            Write-Fail "Could not remove $Dest"
            return $false
        }
        Write-Ok "The newly copied $PluginName folder was removed again."
    } else {
        return $false
    }
    $script:Phase = 'idle'
    return $true
}

# Shown when the window is closed with Ctrl+C or the script stops on an
# unexpected error. Leaves the source folder in a state the user can understand.
function Show-InterruptHelp {
    Write-Host ''
    Write-Warn 'Interrupted, or stopped by an unexpected error.'
    if ($script:Phase -eq 'installed') {
        Write-Info 'The new plugin files were already copied completely and checked:'
        Write-Info "  $Dest"
        Write-Info 'What did not finish is the build or inject step. To finish, open a'
        Write-Info "terminal in $Repo and run 'pnpm build'."
        if ($script:Aside -and (Test-Exists $script:Aside)) {
            Remove-Aside
            Write-Info "Your previous $PluginName folder is kept in the backup:"
            Write-Info "  $(Join-Path $Backup $PluginName)"
            Write-Info 'To go back to it, run uninstall.bat and choose that backup.'
        }
    } else {
        Invoke-Recover
        if ($Existing) {
            Write-Info 'The plugin folder in your source folder is as it was before this run.'
        } elseif ($UserPlugins) {
            Write-Info 'No plugin files were left in your source folder.'
        }
        if ($Backup) { Write-Info "A backup of the previous plugin is also in: $Backup" }
    }
    Write-Host ''
    Write-Host "$ScriptTitle was interrupted." -ForegroundColor Red
}

$script:OnStop = { Invoke-Recover }

try {
    # -------------------------------------------------------------- welcome

    Write-Host 'TypingIndicators installer  by TheAstroMirth' -ForegroundColor White
    Write-Host ''
    Write-Host 'This adds the TypingIndicators plugin to a Vencord or Equicord source folder'
    Write-Host "that is already on this PC, builds it, and can run the client's own inject step."
    Write-Host 'It does not download or install Vencord, Equicord or Discord, and asks before'
    Write-Host 'changing anything that already exists.'
    Write-Host 'Unofficial third-party plugin. Client mods are against the Discord ToS. Use at your own risk.' -ForegroundColor DarkGray

    Assert-Windows
    foreach ($f in $PluginFiles) {
        $p = Join-Path $PluginSrc $f
        if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).Length -eq 0) {
            Stop-Script "Cannot find $PluginName\$f next to the installers. Keep the project folder together."
        }
    }

    Write-Step '1/7  Client'
    $Client = Select-Client

    Write-Step '2/7  Prerequisites'
    if (-not (Test-Tools)) { Stop-Script 'Missing prerequisites.' }

    Write-Step '3/7  Source folder'
    $sel = Select-Checkout $Client
    $Repo = $sel.Repo
    $Client = $sel.Client
    $Label = Get-ClientLabel $Client
    if (-not (Test-NodeVersion $Repo $Label)) { Stop-Script "Node.js is too old for this $Label source folder." }

    Write-Step '4/7  Existing installation'
    $UserPlugins = Join-Path (Join-Path $Repo 'src') 'userplugins'
    $Dest = Join-Path $UserPlugins $PluginName

    $leftover = Show-Leftovers $UserPlugins $Label
    if ($leftover -and -not (Find-ExistingPlugin $UserPlugins)) {
        Write-Info "There is no $PluginName folder right now, so that folder is your last installation."
        if (Ask-YesNo "Put it back as '$PluginName' before continuing?" $true) {
            try {
                Move-Entry $leftover $Dest
            } catch {
                Stop-Script "Could not rename $leftover ($($_.Exception.Message))"
            }
            Write-Ok "Put back: $Dest"
        }
    }

    $Existing = Find-ExistingPlugin $UserPlugins
    if (-not $Existing) {
        Write-Ok 'No existing TypingIndicators installation in this source folder.'
    } elseif (Test-SameAsPackage $Existing) {
        $Mode = 'same'
        Write-Ok 'TypingIndicators is already installed here and the plugin files are identical.'
    } else {
        Write-Warn 'An existing TypingIndicators installation was found:'
        Write-Info "  $Existing"
        if (Test-IsLink $Existing) {
            Write-Info 'It is a link to another folder.'
            Write-Info 'Replacing removes only the link, never the folder it points to.'
            Write-Info '  [1] Replace  - back up its contents, then put a fresh copy in its place'
            Write-Info '  [2] Cancel   - change nothing'
            $choices = @('replace', 'cancel')
        } elseif (-not (Test-Path -LiteralPath $Existing -PathType Container)) {
            Write-Info 'It is a file, not a folder.'
            Write-Info '  [1] Replace  - back it up, then put the plugin folder in its place'
            Write-Info '  [2] Cancel   - change nothing'
            $choices = @('replace', 'cancel')
        } else {
            Write-Info '  [1] Update   - back it up, then replace index.tsx and style.css (other files stay)'
            Write-Info '  [2] Replace  - back it up, then replace the whole folder with a fresh copy'
            Write-Info '  [3] Cancel   - change nothing'
            $choices = @('update', 'replace', 'cancel')
        }
        $pick = 0
        if ($Yes) {
            $pick = 1
        } else {
            while ($pick -lt 1 -or $pick -gt $choices.Count) {
                $reply = Read-Host ("   Choose 1-{0}" -f $choices.Count)
                if ($null -eq $reply) { $pick = $choices.Count; break }
                if (-not [int]::TryParse($reply.Trim(), [ref]$pick)) { $pick = 0 }
            }
        }
        $Mode = $choices[$pick - 1]
        if ($Mode -eq 'cancel') { Stop-Script 'Cancelled. The existing installation was not changed.' }

        $Backup = New-PluginBackup $Existing $Client $Repo
        if (-not $Backup) { Stop-Script "Could not back up the existing plugin to $(Get-BackupRoot). Nothing was replaced." }
        Write-Ok "Backup saved and checked: $(Join-Path $Backup $PluginName)"
    }

    Write-Step '5/7  Copying the plugin'
    if ($Mode -eq 'same') {
        $Copied = 'already'
        Write-Ok 'Nothing to copy.'
    } else {
        $problem = Install-Plugin
        if ($problem) {
            Write-Fail "The plugin could not be installed: $problem."
            Invoke-Recover
            if ($Backup) { Write-Info "The backup made in this run is in: $Backup" }
            Stop-Script 'Nothing was installed.'
        }
        $Copied = 'yes'
        foreach ($f in $PluginFiles) { Write-Ok "Copied and verified: $(Join-Path $Dest $f)" }
    }

    Write-Step "6/7  Building $Label"
    if ($NoBuild) {
        $Built = 'skipped'
        Write-Warn "Skipped (-NoBuild). Run 'pnpm build' in the source folder yourself."
    } elseif (Confirm-Dependencies $Repo $Label) {
        if (Invoke-Build $Repo) { $Built = 'yes' } else { $Built = 'failed' }
    } else {
        $Built = 'nodeps'
        Write-Fail "$Label was not built because its dependencies are not installed."
    }

    if ($Built -eq 'failed') {
        Write-Host ''
        Write-Warn 'What this means:'
        Write-Info "- 'pnpm build' stopped with an error, shown above. Read it first: it may"
        Write-Info '  come from the source folder itself (out of date, changed) and not from'
        Write-Info '  this plugin.'
        Write-Info '- Until a build succeeds, the plugin files are only sitting in the source'
        Write-Info '  folder. They are not active in Discord.'
        if ($Mode -eq 'update' -or $Mode -eq 'replace') {
            Write-Info "- Your previous $PluginName folder has not been deleted. It is kept next to"
            Write-Info '  the new one, and a checked backup is in:'
            Write-Info "    $(Join-Path $Backup $PluginName)"
            Write-Host ''
            Write-Info 'You can roll back: the new files are removed and your previous folder is'
            Write-Info 'put back exactly as it was. Or keep the new files and fix the build.'
            if (Ask-YesNo "Roll back to your previous $PluginName folder?" $false) {
                if (Undo-Install) { $Copied = 'rolledback' }
            } else {
                Write-Info 'Keeping the new files.'
            }
        } elseif ($Mode -eq 'fresh') {
            Write-Info "- There was no $PluginName folder before this run, so nothing of yours was replaced."
            Write-Host ''
            Write-Info 'You can roll back: the folder copied in this run is removed again.'
            if (Ask-YesNo "Remove the newly copied $PluginName folder again?" $false) {
                if (Undo-Install) { $Copied = 'rolledback' }
            } else {
                Write-Info 'Keeping the new files.'
            }
        } else {
            Write-Info '- The plugin files were already in place and were not changed by this run,'
            Write-Info '  so there is nothing to roll back.'
        }
        if ($Copied -eq 'rolledback') {
            Write-Info 'The source folder still needs one successful build.'
            if (Ask-YesNo "Run 'pnpm build' again now?" $true) {
                if (Invoke-Build $Repo) { $Rebuilt = 'yes' } else { $Rebuilt = 'failed' }
            } else {
                $Rebuilt = 'no'
            }
        }
    }

    # From here on the previous folder is no longer needed next to the new one.
    if ($script:Aside) {
        Remove-Aside
        Write-Info "Your previous $PluginName folder stays available in the backup: $Backup"
    }

    Write-Step '7/7  Inject'
    if ($Built -ne 'yes') {
        $Injected = 'skipped'
        Write-Info "Skipped, because $Label was not built successfully in this run."
    } else {
        Write-Info "'pnpm inject' is $Label's own tool that makes Discord load this build."
        Write-Info "It fetches the official $Label installer and asks which Discord to patch."
        Write-Info 'You only need it if Discord is not already using this source folder.'
        Write-Info 'Close Discord completely (also from the system tray) before running it.'
        if (-not $Yes -and (Ask-YesNo "Run 'pnpm inject' now?" $false)) {
            Write-Host ''
            Push-Location -LiteralPath $Repo
            try {
                & pnpm inject | Out-Host
                $rc = $LASTEXITCODE
            } finally { Pop-Location }
            Write-Host ''
            if ($rc -eq 0) {
                $Injected = 'yes'
                Write-Ok 'pnpm inject finished'
            } else {
                $Injected = 'failed'
                Write-Fail "pnpm inject did not succeed (exit code $rc). See the output above."
                Write-Info "You can run it again later: open a terminal in $Repo and run 'pnpm inject'"
            }
        } else {
            $Injected = 'skipped'
            Write-Info "Not run. To do it later, open a terminal in $Repo and run 'pnpm inject'"
        }
    }

    # -------------------------------------------------------------- summary

    $script:Completed = $true
    Write-Host ''
    Write-Host 'Summary' -ForegroundColor White
    if ($Copied -eq 'yes') { Write-Ok "Plugin copied:  yes  ($Dest)" }
    elseif ($Copied -eq 'already') { Write-Ok "Plugin copied:  already in place, identical  ($Dest)" }
    elseif ($Copied -eq 'rolledback') { Write-Warn 'Plugin copied:  rolled back, the source folder is as it was before this run' }
    else { Write-Fail 'Plugin copied:  no' }

    if ($Built -eq 'yes') { Write-Ok "$Label built:  yes" }
    elseif ($Built -eq 'skipped') { Write-Warn "$Label built:  skipped" }
    elseif ($Built -eq 'nodeps') { Write-Fail "$Label built:  NO, its dependencies are not installed" }
    else { Write-Fail "$Label built:  NO, the build did not succeed" }

    if ($Rebuilt -eq 'yes') { Write-Ok 'Build after rolling back:  yes' }
    elseif ($Rebuilt -eq 'failed') { Write-Fail 'Build after rolling back:  NO, it failed again' }
    elseif ($Rebuilt -eq 'no') { Write-Warn 'Build after rolling back:  not run' }

    if ($Injected -eq 'yes') { Write-Ok 'Injected:  yes' }
    elseif ($Injected -eq 'failed') { Write-Fail "Injected:  NO, 'pnpm inject' failed" }
    else { Write-Info '  Injected:  not run' }

    if ($Backup) { Write-Info "  Backup of the previous plugin: $Backup" }

    Write-Host ''
    if ($Copied -eq 'rolledback') {
        Write-Host 'TypingIndicators was NOT installed. The change was rolled back.' -ForegroundColor Red
        if ($Rebuilt -eq 'yes') {
            Write-Host "$Label was built again without the new files."
        } elseif ($Rebuilt -eq 'failed') {
            Write-Host 'The build fails even without the new files, so the problem is in the source'
            Write-Host "folder itself. Fix it there (for example 'git pull' and 'pnpm install'), then"
            Write-Host 'run this installer again.'
        } else {
            Write-Host "Before using Discord with this build, open a terminal in $Repo and run 'pnpm build'."
        }
        $ExitCode = 1
    } elseif ($Built -eq 'yes' -and $Injected -ne 'failed') {
        Write-Host "Done. TypingIndicators was installed and $Label was built successfully." -ForegroundColor Green
        Write-Host 'Next:'
        Write-Host '  1. Close Discord completely (also from the system tray) and open it again.'
        Write-Host "  2. Open Discord Settings > $Label > Plugins, search for TypingIndicators"
        Write-Host '     and turn it on. Restart Discord if it asks.'
        if ($Injected -ne 'yes') {
            Write-Host '  If the plugin is not in the list, Discord is not using this build yet.'
            Write-Host "  Open a terminal in $Repo and run 'pnpm inject'."
        }
        $ExitCode = 0
    } elseif ($Built -eq 'yes') {
        Write-Host "TypingIndicators was copied and $Label was built, but injecting failed." -ForegroundColor Yellow
        Write-Host "Close Discord completely, then open a terminal in $Repo and run 'pnpm inject'."
        Write-Host "After that, turn the plugin on in Discord Settings > $Label > Plugins."
        $ExitCode = 1
    } elseif ($Built -eq 'skipped') {
        Write-Host "TypingIndicators was copied, but $Label has not been built yet." -ForegroundColor Yellow
        Write-Host "When you are ready, open a terminal in $Repo and run 'pnpm build'."
        Write-Host "Then restart Discord and turn the plugin on in Settings > $Label > Plugins."
        $ExitCode = 0
    } else {
        Write-Host "TypingIndicators was copied, but $Label was NOT built." -ForegroundColor Red
        Write-Host 'The plugin will not show up in Discord until the build succeeds.'
        if ($Built -eq 'nodeps') {
            Write-Host "Open a terminal in $Repo and run 'pnpm install --frozen-lockfile', then 'pnpm build'."
        } else {
            Write-Host "Fix the problem shown above, then open a terminal in $Repo and run 'pnpm build'."
        }
        if ($Backup) {
            Write-Host 'To go back to your previous plugin instead, run uninstall.bat and'
            Write-Host "choose the backup $(Split-Path -Path $Backup -Leaf)."
        } else {
            Write-Host 'To remove the plugin again, run uninstall.bat.'
        }
        $ExitCode = 1
    }
} finally {
    # Runs on a normal end, on Stop-Script, on Ctrl+C and on unexpected errors.
    if (-not $script:Completed) {
        if (-not $script:Stopping) { Show-InterruptHelp }
        Invoke-Recover
    }
}
exit $ExitCode
