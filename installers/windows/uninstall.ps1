# TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
# Installer scripts: Copyright (c) 2026 TheAstroMirth.
# Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
#
# TypingIndicators uninstaller for Windows 10/11.
# Removes only src\userplugins\TypingIndicators from a Vencord or Equicord source folder.
# It never removes Vencord, Equicord, Discord, other plugins or any backup.
#
# Options:
#   -Client NAME    vencord or equicord (skips the question)
#   -Source "PATH"  Your Vencord/Equicord source folder (skips the question)
#   -Yes            Do not ask questions, use the default answers
#                   (needs -Client and -Source; never restores a backup)
#   -NoBuild        Remove the plugin but do not run 'pnpm build'

param(
    [string]$Client = '',
    [string]$Source = '',
    [switch]$Yes,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$ScriptTitle = 'TypingIndicators uninstall'
$CommonFile = Join-Path $PSScriptRoot 'common.ps1'
if (-not (Test-Path -LiteralPath $CommonFile -PathType Leaf)) {
    Write-Host 'Cannot find common.ps1 next to uninstall.ps1. Keep the project folder together.' -ForegroundColor Red
    exit 1
}
. $CommonFile

$ExitCode = 1
$script:Completed = $false

# A restore copies into a working folder first. Never leave that behind.
function Clear-RestoreStage {
    try {
        if ($script:RestoreStage -and (Test-Exists $script:RestoreStage)) { Remove-Entry $script:RestoreStage }
    } catch { }
    $script:RestoreStage = $null
}

$script:OnStop = { Clear-RestoreStage }

try {
    Write-Host 'TypingIndicators uninstaller  by TheAstroMirth' -ForegroundColor White
    Write-Host ''
    Write-Host 'This removes the TypingIndicators plugin folder from your Vencord or Equicord'
    Write-Host 'source folder. Nothing else is removed.'

    Assert-Windows

    Write-Step '1/5  Client'
    $Client = Select-Client

    Write-Step '2/5  Source folder'
    $sel = Select-Checkout $Client
    $Repo = $sel.Repo
    $Client = $sel.Client
    $Label = Get-ClientLabel $Client

    $UserPlugins = Join-Path (Join-Path $Repo 'src') 'userplugins'
    $Dest = Join-Path $UserPlugins $PluginName

    Write-Step '3/5  Removing the plugin'
    $Removed = $false
    $Restored = $false
    [void](Show-Leftovers $UserPlugins $Label)
    $Target = Find-ExistingPlugin $UserPlugins
    if (-not $Target) {
        Write-Ok 'TypingIndicators is not installed in this source folder. Nothing to remove.'
    } else {
        # Safety: only ever touch <source folder>\src\userplugins\TypingIndicators.
        if ((Split-Path -Path $Target -Leaf) -ine $PluginName -or (Split-Path -Path (Split-Path -Path $Target -Parent) -Leaf) -ine 'userplugins') {
            Stop-Script "Refusing to remove an unexpected path: $Target"
        }
        $isLink = Test-IsLink $Target
        $isDir = Test-Path -LiteralPath $Target -PathType Container
        Write-Info 'This will remove only this folder:'
        Write-Info "  $Target"
        if ($isLink) {
            Write-Info 'It is a link. Only the link is removed, not the folder it points to.'
        } elseif ($isDir) {
            Write-Info 'Contents:'
            foreach ($c in @(Get-ChildItem -LiteralPath $Target -Force -ErrorAction SilentlyContinue)) { Write-Info "    $($c.Name)" }
            $index = Join-Path $Target 'index.tsx'
            if (Test-Path -LiteralPath $index -PathType Leaf) {
                if (-not (Select-String -LiteralPath $index -Pattern $PluginName -SimpleMatch -Quiet)) {
                    Write-Warn 'index.tsx in that folder does not look like the TypingIndicators plugin.'
                }
            }
        }
        Write-Info "Other plugins, $Label and Discord are not touched."
        if (-not (Ask-YesNo 'Remove it?' $true)) { Stop-Script 'Cancelled. Nothing was removed.' }
        try {
            Remove-Entry $Target
        } catch {
            Stop-Script "Could not remove $Target ($($_.Exception.Message))"
        }
        if (Test-Exists $Target) { Stop-Script "Could not remove $Target" }
        $Removed = $true
        Write-Ok "Removed $Target"
    }

    Write-Step '4/5  Backups'
    $BackupRoot = Get-BackupRoot
    $Backups = @(Get-Backups $Client $Repo)
    $Others = Get-OtherBackupCount $Client $Repo
    if ($Backups.Count -eq 0) {
        Write-Info 'No backups were found for this source folder.'
    } else {
        Write-Info 'Backups of an earlier TypingIndicators folder taken from this source folder:'
        for ($i = 0; $i -lt $Backups.Count; $i++) {
            $name = Split-Path -Path $Backups[$i] -Leaf
            $check = Test-Backup $Backups[$i] $Client $Repo
            if ($check.Ok) {
                Write-Host ("     [{0}] {1}" -f ($i + 1), $name)
            } else {
                Write-Host ("     [{0}] {1}  (cannot be restored: {2})" -f ($i + 1), $name, $check.Problem)
            }
        }
        Write-Info "They are kept in: $BackupRoot"
        if (Find-ExistingPlugin $UserPlugins) {
            Write-Info 'Nothing is restored while a TypingIndicators folder is still in place.'
        } elseif ($Yes) {
            Write-Info 'Not restoring anything (-Yes).'
        } else {
            while ($true) {
                $reply = Read-Host '   Restore one into this source folder? Type its number, or press Enter to skip'
                if ($null -eq $reply -or -not $reply.Trim()) { break }
                $n = 0
                if (-not [int]::TryParse($reply.Trim(), [ref]$n)) { continue }
                if ($n -lt 1 -or $n -gt $Backups.Count) { continue }
                $chosen = $Backups[$n - 1]
                # Check again right before use: the right source folder, real plugin
                # files, and unchanged since the backup was made.
                $check = Test-Backup $chosen $Client $Repo
                if (-not $check.Ok) {
                    Write-Fail "That backup cannot be restored: $($check.Problem)."
                    Write-Info 'Nothing was changed. Choose another one or press Enter to skip.'
                    continue
                }
                if ($check.Note) { Write-Warn "Note for this backup: $($check.Note)." }
                $problem = Restore-Backup $chosen $UserPlugins
                if (-not $problem) {
                    $Restored = $true
                    Write-Ok "Restored $(Split-Path -Path $chosen -Leaf) to: $Dest"
                    Write-Ok 'The restored files were compared with the backup and match.'
                    Write-Info 'The backup itself was kept.'
                } else {
                    Write-Fail "The backup was not restored: $problem."
                    Write-Info "The backup is unchanged: $chosen"
                }
                break
            }
        }
        Write-Info 'Backups are never deleted automatically. Delete that folder yourself when you no longer need them.'
    }
    if ($Others -gt 0) {
        Write-Info "$Others other backup(s) in $BackupRoot belong to a different source folder"
        Write-Info 'or client and are not offered here. Run the uninstaller for that folder to restore them.'
    }

    Write-Step "5/5  Rebuilding $Label"
    $Rebuilt = 'no'    # no | yes | failed
    if (-not $Removed -and -not $Restored) {
        Write-Info 'Nothing changed, so no rebuild is needed.'
    } elseif ($NoBuild) {
        Write-Warn "Skipped (-NoBuild). Run 'pnpm build' in the source folder to finish."
    } elseif (-not (Test-Cmd 'pnpm') -or -not (Test-Cmd 'node') -or -not (Test-Path -LiteralPath (Join-Path $Repo 'node_modules'))) {
        Write-Warn 'Cannot rebuild here (Node.js, pnpm or the node_modules folder is missing).'
    } elseif (Ask-YesNo "Rebuild $Label now with 'pnpm build' so the change takes effect?" $true) {
        if (Invoke-Build $Repo) { $Rebuilt = 'yes' } else { $Rebuilt = 'failed' }
    } else {
        Write-Info 'Not rebuilt.'
    }

    $script:Completed = $true
    Write-Host ''
    Write-Host 'Summary' -ForegroundColor White
    if ($Removed) { Write-Ok 'Plugin folder removed:  yes' } else { Write-Info '  Plugin folder removed:  no, it was not installed' }
    if ($Restored) { Write-Ok "Backup restored:  yes  ($Dest)" }
    if ($Rebuilt -eq 'yes') { Write-Ok "$Label rebuilt:  yes" }
    elseif ($Rebuilt -eq 'failed') { Write-Fail "$Label rebuilt:  NO, the build did not succeed" }
    elseif ($Removed -or $Restored) { Write-Warn "$Label rebuilt:  no" }

    Write-Host ''
    if (-not $Removed -and -not $Restored) {
        Write-Host 'Nothing to do.' -ForegroundColor Green
        $ExitCode = 0
    } elseif ($Rebuilt -eq 'yes') {
        Write-Host "Done. $Label was rebuilt." -ForegroundColor Green
        Write-Host 'Close Discord completely (also from the system tray) and open it again for the change to show.'
        $ExitCode = 0
    } elseif ($Rebuilt -eq 'failed') {
        Write-Host 'The plugin folder was changed, but the rebuild failed.' -ForegroundColor Red
        Write-Host "Fix the problem shown above, then open a terminal in $Repo and run 'pnpm build'."
        $ExitCode = 1
    } else {
        Write-Host "The plugin folder was changed, but $Label has not been rebuilt yet." -ForegroundColor Yellow
        Write-Host "Discord keeps using the old build until you open a terminal in $Repo and run 'pnpm build'."
        Write-Host 'Then close Discord completely (also from the system tray) and open it again.'
        $ExitCode = 0
    }
} finally {
    # Runs on a normal end, on Stop-Script, on Ctrl+C and on unexpected errors.
    Clear-RestoreStage
    if (-not $script:Completed -and -not $script:Stopping) {
        Write-Host ''
        Write-Warn 'Interrupted, or stopped by an unexpected error.'
        Write-Info 'No half-restored files were left behind. Backups were not changed.'
        Write-Host ''
        Write-Host "$ScriptTitle was interrupted." -ForegroundColor Red
    }
}
exit $ExitCode
