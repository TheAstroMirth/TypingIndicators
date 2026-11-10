#!/bin/bash
# TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
# Installer scripts: Copyright (c) 2026 TheAstroMirth.
# Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
#
# TypingIndicators installer for macOS (Apple Silicon and Intel).
# Copies the plugin into an existing Vencord or Equicord source folder and builds it.
# It never downloads, clones or installs Vencord or Equicord, and does not use sudo.
#
# How the plugin folder is changed:
#   1. The new folder is prepared and checked under a working name.
#   2. An existing folder is moved aside, the new one is moved into place.
#   3. The folder moved aside is kept until the build result is known, so the
#      previous installation can be put back exactly as it was.
# If anything fails or the run is interrupted during 1 or 2, the previous
# installation is put back automatically.

# shellcheck disable=SC2010,SC2086,SC2329
SCRIPT_TITLE="TypingIndicators install"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ ! -r "$SCRIPT_DIR/common.sh" ]; then
    echo "Cannot find common.sh next to install.sh. Keep the project folder together." >&2
    exit 1
fi
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<USAGE
Usage: install.sh [options]
  --client NAME    vencord or equicord (skips the question)
  --source "PATH"  Your Vencord/Equicord source folder (skips the question)
  --yes            Do not ask questions, use the default answers
                   (needs --client and --source; never runs 'pnpm inject'
                   and never rolls back on its own)
  --no-build       Copy the plugin but do not run 'pnpm build'
  --help           Show this help
USAGE
}

parse_args "$@"

PLUGIN_SRC="$SCRIPT_DIR/../../$PLUGIN_NAME"

COPIED="no"        # no | yes | already | rolledback
BUILT="no"         # no | yes | skipped | failed | nodeps
INJECTED="no"      # no | yes | skipped | failed
REBUILT=""         # after a rollback: yes | failed | no
BACKUP_DIR=""
USERPLUGINS=""
DEST=""
EXISTING=""
MODE="fresh"       # fresh | update | replace | same
PHASE="idle"       # idle | staging | swapping | installed
STAGE=""           # new folder being prepared
ASIDE=""           # previous folder, moved aside
ASIDE_ORIG=""      # where the previous folder came from

# Puts the previous installation back after a swap that did not complete.
# Returns 0 when src/userplugins is as it was before this run.
undo_swap() {
    if [ -n "$ASIDE" ] && exists "$ASIDE"; then
        # The previous folder is safe in $ASIDE, so anything at $DEST is the new copy.
        exists "$DEST" && remove_entry "$DEST"
        if ! exists "$ASIDE_ORIG" && mv "$ASIDE" "$ASIDE_ORIG"; then
            ok "Your previous $PLUGIN_NAME folder was put back: $ASIDE_ORIG"
            ASIDE=""
            return 0
        fi
        fail "Your previous $PLUGIN_NAME folder could not be put back automatically."
        info "It is safe here:  $ASIDE"
        info "To restore it, rename that folder to '$PLUGIN_NAME'."
        [ -n "$BACKUP_DIR" ] && info "A second copy is in the backup: $BACKUP_DIR/$PLUGIN_NAME"
        ASIDE=""
        return 1
    fi
    return 0
}

# Brings src/userplugins back to a consistent state, whatever step was reached.
recover() {
    if [ -n "$STAGE" ] && exists "$STAGE"; then remove_entry "$STAGE"; fi
    STAGE=""
    if [ "$PHASE" = "swapping" ]; then
        undo_swap
        PHASE="idle"
    fi
}

on_exit() {
    local rc=$?
    trap - EXIT
    recover
    exit "$rc"
}

on_interrupt() {
    trap - INT TERM HUP
    echo
    warn "Interrupted."
    case "$PHASE" in
        installed)
            info "The new plugin files were already copied completely and checked:"
            info "  $DEST"
            info "What did not finish is the build or inject step. To finish:"
            info "  cd \"$REPO\" && pnpm build"
            if [ -n "$ASIDE" ] && exists "$ASIDE"; then
                remove_entry "$ASIDE"; ASIDE=""
                info "Your previous $PLUGIN_NAME folder is kept in the backup:"
                info "  $BACKUP_DIR/$PLUGIN_NAME"
                info "To go back to it, run uninstall.command and choose that backup."
            fi
            ;;
        *)
            recover
            if [ -n "$EXISTING" ]; then
                info "The plugin folder in your source folder is as it was before this run."
            else
                info "No plugin files were left in your source folder."
            fi
            [ -n "$BACKUP_DIR" ] && info "A backup of the previous plugin is also in: $BACKUP_DIR"
            ;;
    esac
    printf '\n%s%s was interrupted.%s\n' "$C_RED" "$SCRIPT_TITLE" "$C_OFF" >&2
    trap - EXIT
    exit 130
}
trap on_exit EXIT
trap on_interrupt INT TERM HUP

same_as_package() {
    local dir="$1" f
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    [ "$(basename "$dir")" = "$PLUGIN_NAME" ] || return 1
    for f in $PLUGIN_FILES; do
        cmp -s "$PLUGIN_SRC/$f" "$dir/$f" || return 1
    done
    return 0
}

# Checks that a folder holds both plugin files, byte for byte, with exact names.
verify_plugin_dir() {
    local dir="$1" f
    for f in $PLUGIN_FILES; do
        [ -f "$dir/$f" ] && [ ! -L "$dir/$f" ] || return 1
        cmp -s "$PLUGIN_SRC/$f" "$dir/$f" || return 1
        ls -1 "$dir" | grep -q -x -F "$f" || return 1
    done
    return 0
}

# install_plugin -> 0 when $DEST holds the new plugin. On any failure nothing
# is left half done: the caller runs recover, which puts the previous folder back.
install_plugin() {
    local f
    INSTALL_ERROR=""
    mkdir -p "$USERPLUGINS" || { INSTALL_ERROR="could not create $USERPLUGINS"; return 1; }

    # 1. Prepare and check the new folder under a working name.
    PHASE="staging"
    STAGE=$(stage_path "$USERPLUGINS" new)
    if exists "$STAGE"; then
        INSTALL_ERROR="a working folder is in the way: $STAGE"; STAGE=""; return 1
    fi
    if [ "$MODE" = "update" ]; then
        cp -RPp "$EXISTING" "$STAGE" || { INSTALL_ERROR="could not copy the existing folder"; return 1; }
    else
        mkdir "$STAGE" || { INSTALL_ERROR="could not create a working folder in $USERPLUGINS"; return 1; }
    fi
    for f in $PLUGIN_FILES; do
        rm -f "${STAGE:?}/${f:?}" || { INSTALL_ERROR="could not replace $f"; return 1; }
        cp "$PLUGIN_SRC/$f" "$STAGE/$f" || { INSTALL_ERROR="could not copy $f"; return 1; }
    done
    verify_plugin_dir "$STAGE" || { INSTALL_ERROR="the copied files did not match the originals"; return 1; }
    if [ "$MODE" = "update" ]; then
        # every other file of the existing folder must have come along unchanged
        diff -r -x index.tsx -x style.css "$EXISTING" "$STAGE" >/dev/null 2>&1 \
            || { INSTALL_ERROR="the other files of the existing folder could not be carried over"; return 1; }
    fi

    # 2. Swap: previous folder aside, new folder into place.
    PHASE="swapping"
    if [ -n "$EXISTING" ]; then
        ASIDE=$(stage_path "$USERPLUGINS" old)
        ASIDE_ORIG="$EXISTING"
        if exists "$ASIDE" || ! mv "$EXISTING" "$ASIDE"; then
            ASIDE=""
            INSTALL_ERROR="could not move the existing plugin aside"; return 1
        fi
    fi
    mv "$STAGE" "$DEST" || { INSTALL_ERROR="could not move the new folder into place"; return 1; }
    STAGE=""
    verify_plugin_dir "$DEST" || { INSTALL_ERROR="the installed files did not match the originals"; return 1; }
    [ "$(find_existing_plugin "$USERPLUGINS")" = "$DEST" ] \
        || { INSTALL_ERROR="the plugin folder did not end up with the right name"; return 1; }
    PHASE="installed"
    return 0
}

# Drops the copy that was moved aside. A checked backup of it exists.
drop_aside() {
    if [ -n "$ASIDE" ] && exists "$ASIDE"; then
        remove_entry "$ASIDE"
        exists "$ASIDE" && warn "Could not remove the working copy $ASIDE (it is not used, you can delete it)"
    fi
    ASIDE=""
}

# Undoes this run's change to the plugin folder. Returns 0 when done.
roll_back_install() {
    case "$MODE" in
        update|replace)
            if [ -z "$ASIDE" ] || ! exists "$ASIDE"; then
                fail "The previous folder is no longer in the source folder."
                info "Restore it from the backup with uninstall.command: $BACKUP_DIR"
                return 1
            fi
            undo_swap || return 1
            ;;
        fresh)
            # Only remove what this run put there, and only if it is still ours.
            if ! same_as_package "$DEST"; then
                fail "$DEST has changed since it was copied, so it was left alone."
                return 1
            fi
            remove_entry "$DEST"
            if exists "$DEST"; then fail "Could not remove $DEST"; return 1; fi
            ok "The newly copied $PLUGIN_NAME folder was removed again."
            ;;
        *) return 1 ;;
    esac
    PHASE="idle"
    return 0
}

# ------------------------------------------------------------------ welcome

printf '%sTypingIndicators installer%s  by TheAstroMirth\n' "$C_BOLD" "$C_OFF"
echo
echo "This adds the TypingIndicators plugin to a Vencord or Equicord source folder"
echo "that is already on this Mac, builds it, and can run the client's own inject step."
echo "It does not download or install Vencord, Equicord or Discord, and asks before"
echo "changing anything that already exists."
printf '%sUnofficial third-party plugin. Client mods are against the Discord ToS. Use at your own risk.%s\n' "$C_DIM" "$C_OFF"

require_macos
for f in $PLUGIN_FILES; do
    [ -f "$PLUGIN_SRC/$f" ] && [ -s "$PLUGIN_SRC/$f" ] \
        || die "Cannot find $PLUGIN_NAME/$f next to the installers. Keep the project folder together."
done
extend_path

step "1/7  Client"
select_client

step "2/7  Prerequisites"
check_tools || die "Missing prerequisites."

step "3/7  Source folder"
select_checkout
check_node_version || die "Node.js is too old for this $CLIENT_LABEL source folder."

step "4/7  Existing installation"
USERPLUGINS="$REPO/src/userplugins"
DEST="$USERPLUGINS/$PLUGIN_NAME"

report_leftovers "$USERPLUGINS"
if [ -n "$LEFTOVER_OLD" ] && ! find_existing_plugin "$USERPLUGINS" >/dev/null; then
    info "There is no $PLUGIN_NAME folder right now, so that folder is your last installation."
    if ask "Put it back as '$PLUGIN_NAME' before continuing?" y; then
        mv "$LEFTOVER_OLD" "$DEST" || die "Could not rename $LEFTOVER_OLD"
        ok "Put back: $DEST"
    fi
fi

if EXISTING=$(find_existing_plugin "$USERPLUGINS"); then
    if same_as_package "$EXISTING"; then
        MODE="same"
        ok "TypingIndicators is already installed here and the plugin files are identical."
    else
        warn "An existing TypingIndicators installation was found:"
        info "  $EXISTING"
        if [ -L "$EXISTING" ]; then
            info "It is a link to: $(readlink "$EXISTING")"
            info "Replacing removes only the link, never the folder it points to."
            info "  [1] Replace  - back up the link, then put a fresh copy in its place"
            info "  [2] Cancel   - change nothing"
            choices="replace cancel"
        elif [ ! -d "$EXISTING" ]; then
            info "It is a file, not a folder."
            info "  [1] Replace  - back it up, then put the plugin folder in its place"
            info "  [2] Cancel   - change nothing"
            choices="replace cancel"
        else
            info "  [1] Update   - back it up, then replace index.tsx and style.css (other files stay)"
            info "  [2] Replace  - back it up, then replace the whole folder with a fresh copy"
            info "  [3] Cancel   - change nothing"
            choices="update replace cancel"
        fi
        count=$(printf '%s\n' $choices | wc -l | tr -d ' ')
        if [ "$OPT_YES" = "1" ]; then
            pick=1
        else
            while :; do
                printf '   Choose 1-%s: ' "$count"
                IFS= read -r pick || pick="$count"
                case "$pick" in ''|*[!0-9]*) continue ;; esac
                [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ] && break
            done
        fi
        MODE=$(printf '%s\n' $choices | sed -n "${pick}p")
        [ "$MODE" = "cancel" ] && die "Cancelled. The existing installation was not changed."

        if ! backup_plugin "$EXISTING"; then
            [ -n "$BACKUP_DIR" ] && info "An unfinished backup folder may be left at: $BACKUP_DIR"
            BACKUP_DIR=""
            die "Could not back up the existing plugin to $BACKUP_ROOT. Nothing was replaced."
        fi
        ok "Backup saved and checked: $BACKUP_DIR/$PLUGIN_NAME"
    fi
else
    EXISTING=""
    ok "No existing TypingIndicators installation in this source folder."
fi

step "5/7  Copying the plugin"
if [ "$MODE" = "same" ]; then
    COPIED="already"
    ok "Nothing to copy."
else
    if ! install_plugin; then
        fail "The plugin could not be installed: $INSTALL_ERROR."
        recover
        [ -n "$BACKUP_DIR" ] && info "The backup made in this run is in: $BACKUP_DIR"
        die "Nothing was installed."
    fi
    COPIED="yes"
    for f in $PLUGIN_FILES; do ok "Copied and verified: $DEST/$f"; done
fi

step "6/7  Building $CLIENT_LABEL"
if [ "$OPT_NO_BUILD" = "1" ]; then
    BUILT="skipped"
    warn "Skipped (--no-build). Run 'pnpm build' in the source folder yourself."
elif check_dependencies; then
    if run_build; then BUILT="yes"; else BUILT="failed"; fi
else
    BUILT="nodeps"
    fail "$CLIENT_LABEL was not built because its dependencies are not installed."
fi

if [ "$BUILT" = "failed" ]; then
    echo
    warn "What this means:"
    info "- 'pnpm build' stopped with an error, shown above. Read it first: it may"
    info "  come from the source folder itself (out of date, changed) and not from"
    info "  this plugin."
    info "- Until a build succeeds, the plugin files are only sitting in the source"
    info "  folder. They are not active in Discord."
    case "$MODE" in
        update|replace)
            info "- Your previous $PLUGIN_NAME folder has not been deleted. It is kept next to"
            info "  the new one, and a checked backup is in:"
            info "    $BACKUP_DIR/$PLUGIN_NAME"
            echo
            info "You can roll back: the new files are removed and your previous folder is"
            info "put back exactly as it was. Or keep the new files and fix the build."
            if ask "Roll back to your previous $PLUGIN_NAME folder?" n; then
                if roll_back_install; then COPIED="rolledback"; fi
            else
                info "Keeping the new files."
            fi
            ;;
        fresh)
            info "- There was no $PLUGIN_NAME folder before this run, so nothing of yours was replaced."
            echo
            info "You can roll back: the folder copied in this run is removed again."
            if ask "Remove the newly copied $PLUGIN_NAME folder again?" n; then
                if roll_back_install; then COPIED="rolledback"; fi
            else
                info "Keeping the new files."
            fi
            ;;
        same)
            info "- The plugin files were already in place and were not changed by this run,"
            info "  so there is nothing to roll back."
            ;;
    esac
    if [ "$COPIED" = "rolledback" ]; then
        info "The source folder still needs one successful build."
        if ask "Run 'pnpm build' again now?" y; then
            if run_build; then REBUILT="yes"; else REBUILT="failed"; fi
        else
            REBUILT="no"
        fi
    fi
fi

# From here on the previous folder is no longer needed next to the new one.
if [ -n "$ASIDE" ]; then
    drop_aside
    info "Your previous $PLUGIN_NAME folder stays available in the backup: $BACKUP_DIR"
fi

step "7/7  Inject"
if [ "$BUILT" != "yes" ]; then
    INJECTED="skipped"
    info "Skipped, because $CLIENT_LABEL was not built successfully in this run."
else
    info "'pnpm inject' is $CLIENT_LABEL's own tool that makes Discord load this build."
    info "It fetches the official $CLIENT_LABEL installer and asks which Discord to patch."
    info "You only need it if Discord is not already using this source folder."
    info "Quit Discord completely (Cmd+Q) before running it."
    if [ "$OPT_YES" != "1" ] && ask "Run 'pnpm inject' now?" n; then
        echo
        ( cd "$REPO" && pnpm inject )
        rc=$?
        echo
        if [ $rc -eq 0 ]; then
            INJECTED="yes"
            ok "pnpm inject finished"
        else
            INJECTED="failed"
            fail "pnpm inject did not succeed (exit code $rc). See the output above."
            info "You can run it again later:  cd \"$REPO\" && pnpm inject"
        fi
    else
        INJECTED="skipped"
        info "Not run. To do it later:  cd \"$REPO\" && pnpm inject"
    fi
fi

# ------------------------------------------------------------------ summary

trap - INT TERM HUP
echo
printf '%sSummary%s\n' "$C_BOLD" "$C_OFF"
case "$COPIED" in
    yes)        ok   "Plugin copied:  yes  ($DEST)" ;;
    already)    ok   "Plugin copied:  already in place, identical  ($DEST)" ;;
    rolledback) warn "Plugin copied:  rolled back, the source folder is as it was before this run" ;;
    *)          fail "Plugin copied:  no" ;;
esac
case "$BUILT" in
    yes)     ok   "$CLIENT_LABEL built:  yes" ;;
    skipped) warn "$CLIENT_LABEL built:  skipped" ;;
    nodeps)  fail "$CLIENT_LABEL built:  NO, its dependencies are not installed" ;;
    *)       fail "$CLIENT_LABEL built:  NO, the build did not succeed" ;;
esac
case "$REBUILT" in
    yes)    ok   "Build after rolling back:  yes" ;;
    failed) fail "Build after rolling back:  NO, it failed again" ;;
    no)     warn "Build after rolling back:  not run" ;;
esac
case "$INJECTED" in
    yes)     ok   "Injected:  yes" ;;
    failed)  fail "Injected:  NO, 'pnpm inject' failed" ;;
    *)       info "  Injected:  not run" ;;
esac
[ -n "$BACKUP_DIR" ] && info "  Backup of the previous plugin: $BACKUP_DIR"

echo
if [ "$COPIED" = "rolledback" ]; then
    printf '%sTypingIndicators was NOT installed. The change was rolled back.%s\n' "$C_RED" "$C_OFF"
    case "$REBUILT" in
        yes)    echo "$CLIENT_LABEL was built again without the new files." ;;
        failed) echo "The build fails even without the new files, so the problem is in the source"
                echo "folder itself. Fix it there (for example 'git pull' and 'pnpm install'), then"
                echo "run this installer again." ;;
        *)      echo "Run this before using Discord with this build:  cd \"$REPO\" && pnpm build" ;;
    esac
    exit 1
elif [ "$BUILT" = "yes" ] && [ "$INJECTED" != "failed" ]; then
    printf '%sDone. TypingIndicators was installed and %s was built successfully.%s\n' "$C_GREEN" "$CLIENT_LABEL" "$C_OFF"
    echo "Next:"
    echo "  1. Quit Discord completely (Cmd+Q) and open it again."
    echo "  2. Open Discord Settings > $CLIENT_LABEL > Plugins, search for TypingIndicators"
    echo "     and turn it on. Restart Discord if it asks."
    if [ "$INJECTED" != "yes" ]; then
        echo "  If the plugin is not in the list, Discord is not using this build yet:"
        echo "     cd \"$REPO\" && pnpm inject"
    fi
    exit 0
elif [ "$BUILT" = "yes" ]; then
    printf '%sTypingIndicators was copied and %s was built, but injecting failed.%s\n' "$C_YELLOW" "$CLIENT_LABEL" "$C_OFF"
    echo "Quit Discord completely, then run:  cd \"$REPO\" && pnpm inject"
    echo "After that, turn the plugin on in Discord Settings > $CLIENT_LABEL > Plugins."
    exit 1
elif [ "$BUILT" = "skipped" ]; then
    printf '%sTypingIndicators was copied, but %s has not been built yet.%s\n' "$C_YELLOW" "$CLIENT_LABEL" "$C_OFF"
    echo "Run this when you are ready:  cd \"$REPO\" && pnpm build"
    echo "Then restart Discord and turn the plugin on in Settings > $CLIENT_LABEL > Plugins."
    exit 0
else
    printf '%sTypingIndicators was copied, but %s was NOT built.%s\n' "$C_RED" "$CLIENT_LABEL" "$C_OFF"
    echo "The plugin will not show up in Discord until the build succeeds."
    if [ "$BUILT" = "nodeps" ]; then
        echo "Run:  cd \"$REPO\" && pnpm install --frozen-lockfile && pnpm build"
    else
        echo "Fix the problem shown above, then run:  cd \"$REPO\" && pnpm build"
    fi
    if [ -n "$BACKUP_DIR" ]; then
        echo "To go back to your previous plugin instead, run uninstall.command and"
        echo "choose the backup $(basename "$BACKUP_DIR")."
    else
        echo "To remove the plugin again, run uninstall.command."
    fi
    exit 1
fi
