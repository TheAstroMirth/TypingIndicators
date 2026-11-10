#!/bin/bash
# TypingIndicators - https://github.com/TheAstroMirth/TypingIndicators
# Installer scripts: Copyright (c) 2026 TheAstroMirth.
# Licensed under the GNU General Public License v3.0. See LICENSE and NOTICE.md.
#
# TypingIndicators uninstaller for macOS (Apple Silicon and Intel).
# Removes only src/userplugins/TypingIndicators from a Vencord or Equicord source folder.
# It never removes Vencord, Equicord, Discord, other plugins or any backup.

# shellcheck disable=SC2012,SC2329
SCRIPT_TITLE="TypingIndicators uninstall"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ ! -r "$SCRIPT_DIR/common.sh" ]; then
    echo "Cannot find common.sh next to uninstall.sh. Keep the project folder together." >&2
    exit 1
fi
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
    cat <<USAGE
Usage: uninstall.sh [options]
  --client NAME    vencord or equicord (skips the question)
  --source "PATH"  Your Vencord/Equicord source folder (skips the question)
  --yes            Do not ask questions, use the default answers
                   (needs --client and --source; never restores a backup)
  --no-build       Remove the plugin but do not run 'pnpm build'
  --help           Show this help
USAGE
}

parse_args "$@"

# A restore copies into a working folder first. Never leave that behind.
cleanup_restore() {
    if [ -n "$RESTORE_STAGE" ] && exists "$RESTORE_STAGE"; then remove_entry "$RESTORE_STAGE"; fi
    RESTORE_STAGE=""
}
on_exit() {
    local rc=$?
    trap - EXIT
    cleanup_restore
    exit "$rc"
}
on_interrupt() {
    trap - INT TERM HUP
    echo
    warn "Interrupted."
    cleanup_restore
    info "No half-restored files were left behind. Backups were not changed."
    printf '\n%s%s was interrupted.%s\n' "$C_RED" "$SCRIPT_TITLE" "$C_OFF" >&2
    trap - EXIT
    exit 130
}
trap on_exit EXIT
trap on_interrupt INT TERM HUP

printf '%sTypingIndicators uninstaller%s  by TheAstroMirth\n' "$C_BOLD" "$C_OFF"
echo
echo "This removes the TypingIndicators plugin folder from your Vencord or Equicord"
echo "source folder. Nothing else is removed."

require_macos
extend_path

step "1/5  Client"
select_client

step "2/5  Source folder"
select_checkout

USERPLUGINS="$REPO/src/userplugins"
DEST="$USERPLUGINS/$PLUGIN_NAME"

step "3/5  Removing the plugin"
REMOVED=0
RESTORED=0
report_leftovers "$USERPLUGINS"
if ! TARGET=$(find_existing_plugin "$USERPLUGINS"); then
    ok "TypingIndicators is not installed in this source folder. Nothing to remove."
else
    # Safety: only ever touch <source folder>/src/userplugins/TypingIndicators.
    if [ "$(dirname "$TARGET")" != "$USERPLUGINS" ] \
        || [ "$(lower "$(basename "$TARGET")")" != "$(lower "$PLUGIN_NAME")" ]; then
        die "Refusing to remove an unexpected path: $TARGET"
    fi
    info "This will remove only this folder:"
    info "  $TARGET"
    if [ -L "$TARGET" ]; then
        info "It is a link. Only the link is removed, not the folder it points to."
    else
        info "Contents:"
        ls -1A "$TARGET" 2>/dev/null | while IFS= read -r line; do info "    $line"; done
        if [ -f "$TARGET/index.tsx" ] && ! grep -q "$PLUGIN_NAME" "$TARGET/index.tsx"; then
            warn "index.tsx in that folder does not look like the TypingIndicators plugin."
        fi
    fi
    info "Other plugins, $CLIENT_LABEL and Discord are not touched."
    ask "Remove it?" y || die "Cancelled. Nothing was removed."
    remove_entry "$TARGET" || die "Could not remove $TARGET"
    if exists "$TARGET"; then die "Could not remove $TARGET"; fi
    REMOVED=1
    ok "Removed $TARGET"
fi

step "4/5  Backups"
BACKUPS=$(list_backups)
OTHERS=$(count_other_backups)
if [ -z "$BACKUPS" ]; then
    info "No backups were found for this source folder."
else
    info "Backups of an earlier TypingIndicators folder taken from this source folder:"
    i=0
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        i=$((i + 1))
        if validate_backup "$b"; then
            printf '     [%d] %s\n' "$i" "$(basename "$b")"
        else
            printf '     [%d] %s  (cannot be restored: %s)\n' "$i" "$(basename "$b")" "$BACKUP_PROBLEM"
        fi
    done <<LIST
$BACKUPS
LIST
    info "They are kept in: $BACKUP_ROOT"
    if exists "$DEST"; then
        info "Nothing is restored while a TypingIndicators folder is still in place."
    elif [ "$OPT_YES" = "1" ]; then
        info "Not restoring anything (--yes)."
    else
        while :; do
            printf '   Restore one into this source folder? Type its number, or press Return to skip: '
            IFS= read -r pick || pick=""
            [ -z "$pick" ] && break
            case "$pick" in *[!0-9]*) continue ;; esac
            if [ "$pick" -lt 1 ] || [ "$pick" -gt "$i" ]; then continue; fi
            chosen=$(printf '%s\n' "$BACKUPS" | sed -n "${pick}p")
            # Check again right before use: the right source folder, real plugin
            # files, and unchanged since the backup was made.
            if ! validate_backup "$chosen"; then
                fail "That backup cannot be restored: $BACKUP_PROBLEM."
                info "Nothing was changed. Choose another one or press Return to skip."
                continue
            fi
            [ -n "$BACKUP_NOTE" ] && warn "Note for this backup: $BACKUP_NOTE."
            if restore_backup "$chosen" "$USERPLUGINS"; then
                RESTORED=1
                ok "Restored $(basename "$chosen") to: $DEST"
                ok "The restored files were compared with the backup and match."
                info "The backup itself was kept."
            else
                fail "The backup was not restored: $RESTORE_ERROR."
                info "The backup is unchanged: $chosen"
            fi
            break
        done
    fi
    info "Backups are never deleted automatically. Delete that folder yourself when you no longer need them."
fi
if [ "$OTHERS" -gt 0 ] 2>/dev/null; then
    info "$OTHERS other backup(s) in $BACKUP_ROOT belong to a different source folder"
    info "or client and are not offered here. Run the uninstaller for that folder to restore them."
fi

step "5/5  Rebuilding $CLIENT_LABEL"
REBUILT="no"     # no | yes | failed
if [ "$REMOVED" = "0" ] && [ "$RESTORED" = "0" ]; then
    info "Nothing changed, so no rebuild is needed."
elif [ "$OPT_NO_BUILD" = "1" ]; then
    warn "Skipped (--no-build). Run 'pnpm build' in the source folder to finish."
elif ! command -v pnpm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1 || [ ! -d "$REPO/node_modules" ]; then
    warn "Cannot rebuild here (Node.js, pnpm or the node_modules folder is missing)."
elif ask "Rebuild $CLIENT_LABEL now with 'pnpm build' so the change takes effect?" y; then
    if run_build; then REBUILT="yes"; else REBUILT="failed"; fi
else
    info "Not rebuilt."
fi

trap - INT TERM HUP
echo
printf '%sSummary%s\n' "$C_BOLD" "$C_OFF"
if [ "$REMOVED" = "1" ]; then ok "Plugin folder removed:  yes"; else info "  Plugin folder removed:  no, it was not installed"; fi
[ "$RESTORED" = "1" ] && ok "Backup restored:  yes  ($DEST)"
case "$REBUILT" in
    yes)    ok   "$CLIENT_LABEL rebuilt:  yes" ;;
    failed) fail "$CLIENT_LABEL rebuilt:  NO, the build did not succeed" ;;
    *)      if [ "$REMOVED" = "1" ] || [ "$RESTORED" = "1" ]; then warn "$CLIENT_LABEL rebuilt:  no"; fi ;;
esac

echo
if [ "$REMOVED" = "0" ] && [ "$RESTORED" = "0" ]; then
    printf '%sNothing to do.%s\n' "$C_GREEN" "$C_OFF"
    exit 0
elif [ "$REBUILT" = "yes" ]; then
    printf '%sDone. %s was rebuilt.%s\n' "$C_GREEN" "$CLIENT_LABEL" "$C_OFF"
    echo "Quit Discord completely (Cmd+Q) and open it again for the change to show."
    exit 0
elif [ "$REBUILT" = "failed" ]; then
    printf '%sThe plugin folder was changed, but the rebuild failed.%s\n' "$C_RED" "$C_OFF"
    echo "Fix the problem shown above, then run:  cd \"$REPO\" && pnpm build"
    exit 1
else
    printf '%sThe plugin folder was changed, but %s has not been rebuilt yet.%s\n' "$C_YELLOW" "$CLIENT_LABEL" "$C_OFF"
    echo "Discord keeps using the old build until you run:  cd \"$REPO\" && pnpm build"
    echo "Then quit Discord completely (Cmd+Q) and open it again."
    exit 0
fi
