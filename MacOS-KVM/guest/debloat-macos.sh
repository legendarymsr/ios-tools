#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# debloat-macos.sh
#
# Post-install tweaks for a macOS guest running under QEMU TCG (the
# macOS KVM module). The guest is slow, so this turns off indexing,
# animations, Siri, iCloud/App Store background work, analytics, and
# display sleep — without touching the Signed System Volume.
#
# SIP stays on. The script only uses defaults write, launchctl disable
# in the user (gui) domain, mdutil, tmutil, softwareupdate, and pmset.
# It does not edit /System, unload SIP-protected system daemons, or
# disable login, networking, Terminal, or Homebrew.
#
# Run in Terminal on the macOS guest, after you have reached the
# desktop. Use sudo (needed for mdutil, tmutil, pmset, and a few
# /Library preferences). User-level settings are applied to the
# logged-in GUI user, not to root.
#
#   sudo ./debloat-macos.sh
#   sudo ./debloat-macos.sh --clear-dock
#   sudo ./debloat-macos.sh --revert
#   sudo ./debloat-macos.sh --revert --clear-dock
#
# --clear-dock removes default persistent Dock shortcuts (Finder and
# Trash stay). The previous Dock is saved once and restored by
# --revert --clear-dock.
#
# --revert puts settings back to typical macOS defaults (not a
# snapshot of whatever you had before the first run), re-enables the
# launchctl services this script disabled, and turns Spotlight and
# Time Machine scheduling back on. Deleted Time Machine local
# snapshots cannot be restored.
#
set -u

usage() {
  cat <<'EOF'
Usage: sudo ./debloat-macos.sh [--clear-dock] [--revert] [--help]

  --clear-dock   Also empty the Dock of default app shortcuts
                 (Finder and Trash stay). Saved for --revert.
  --revert       Restore typical macOS defaults and re-enable
                 services this script disables.
  --help         Show this help.

Run this in Terminal inside the macOS guest, as sudo, after login.
Do not run it on the Android host.
EOF
}

REVERT=0
CLEAR_DOCK=0
for arg in "$@"; do
  case "$arg" in
    --revert) REVERT=1 ;;
    --clear-dock) CLEAR_DOCK=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'Unknown option: %s\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'This script must be run inside macOS (Darwin), not %s.\n' "$(uname -s)" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  printf 'Please run this script with sudo, in Terminal on the macOS guest.\n' >&2
  printf '  sudo ./debloat-macos.sh\n' >&2
  printf '  curl -fsSL <url> | sudo bash\n' >&2
  exit 1
fi

# GUI user on the console (never root / loginwindow). sudo would otherwise
# write defaults to /var/root and miss the session you are looking at.
console_user() {
  local u
  u=$(stat -f '%Su' /dev/console 2>/dev/null) || u=""
  if [ -n "$u" ] && [ "$u" != "root" ] && [ "$u" != "loginwindow" ]; then
    printf '%s\n' "$u"
    return 0
  fi
  u=$(scutil <<'SC' 2>/dev/null | awk '/Name :/ && $3 != "loginwindow" { print $3 }'
show State:/Users/ConsoleUser
SC
)
  if [ -n "$u" ] && [ "$u" != "root" ]; then
    printf '%s\n' "$u"
    return 0
  fi
  return 1
}

CONSOLE_USER=$(console_user) || CONSOLE_USER=""
if [ -z "$CONSOLE_USER" ]; then
  printf 'Could not find a logged-in GUI user. Log in to the macOS desktop, then run this from Terminal with sudo.\n' >&2
  exit 1
fi
CONSOLE_UID=$(id -u "$CONSOLE_USER") || {
  printf 'Could not resolve uid for %s\n' "$CONSOLE_USER" >&2
  exit 1
}
CONSOLE_HOME=$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [ -z "$CONSOLE_HOME" ] || [ ! -d "$CONSOLE_HOME" ]; then
  CONSOLE_HOME=$(eval "echo ~${CONSOLE_USER}")
fi

DOCK_BACKUP="${CONSOLE_HOME}/.macos-kvm-debloat-Dock-backup.plist"
GUI_DOMAIN="gui/${CONSOLE_UID}"

CHANGED=0
ALREADY=0
SKIPPED=0
FAILED=0

# ---------------------------------------------------------------------------
# Helpers. Each one prints what it did.
# ---------------------------------------------------------------------------

as_user() {
  # Run a command as the GUI user, with that user's HOME.
  sudo -H -u "$CONSOLE_USER" -- "$@"
}

say() { printf '%s\n' "$*"; }

# Compare a `defaults read` value to the value we want. defaults prints
# booleans as 0/1, reals as numbers, strings unquoted here after read.
_same_default() {
  local typ="$1" want="$2" have="$3"
  case "$typ" in
    -bool)
      case "$want" in
        true|TRUE|YES|yes) want=1 ;;
        false|FALSE|NO|no) want=0 ;;
      esac
      case "$have" in
        true|TRUE|YES|yes) have=1 ;;
        false|FALSE|NO|no) have=0 ;;
      esac
      [ "$want" = "$have" ]
      ;;
    -int|-integer)
      [ "$want" = "$have" ]
      ;;
    -float)
      # Allow 0 vs 0.0
      awk -v a="$want" -v b="$have" 'BEGIN { exit (a+0 == b+0) ? 0 : 1 }'
      ;;
    -string)
      [ "$want" = "$have" ]
      ;;
    *)
      [ "$want" = "$have" ]
      ;;
  esac
}

# Write a user default if it is not already the requested value.
user_defaults_write() {
  local domain="$1" key="$2" typ="$3" val="$4"
  local cur
  cur=$(as_user defaults read "$domain" "$key" 2>/dev/null) || cur=""
  if [ -n "$cur" ] && _same_default "$typ" "$val" "$cur"; then
    say "  already: ${domain} ${key} = ${val}"
    ALREADY=$((ALREADY + 1))
    return 0
  fi
  if as_user defaults write "$domain" "$key" "$typ" "$val"; then
    say "  set:     ${domain} ${key} ${typ} ${val}"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  say "  failed:  ${domain} ${key} (left unchanged)"
  FAILED=$((FAILED + 1))
  return 1
}

# Host-scoped default (ByHost), e.g. screensaver and Handoff.
user_defaults_host_write() {
  local domain="$1" key="$2" typ="$3" val="$4"
  local cur
  cur=$(as_user defaults -currentHost read "$domain" "$key" 2>/dev/null) || cur=""
  if [ -n "$cur" ] && _same_default "$typ" "$val" "$cur"; then
    say "  already: ${domain} ${key} (currentHost) = ${val}"
    ALREADY=$((ALREADY + 1))
    return 0
  fi
  if as_user defaults -currentHost write "$domain" "$key" "$typ" "$val"; then
    say "  set:     ${domain} ${key} (currentHost) ${typ} ${val}"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  say "  failed:  ${domain} ${key} (currentHost; left unchanged)"
  FAILED=$((FAILED + 1))
  return 1
}

# Delete a user default (used on revert when the stock state is "unset").
user_defaults_delete() {
  local domain="$1" key="$2"
  if ! as_user defaults read "$domain" "$key" >/dev/null 2>&1; then
    say "  already: ${domain} ${key} is unset"
    ALREADY=$((ALREADY + 1))
    return 0
  fi
  if as_user defaults delete "$domain" "$key" 2>/dev/null; then
    say "  deleted: ${domain} ${key}"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  say "  skipped: ${domain} ${key} (could not delete)"
  SKIPPED=$((SKIPPED + 1))
  return 0
}

# Root-owned plist under /Library/Preferences or a full plist path.
root_defaults_write() {
  local domain="$1" key="$2" typ="$3" val="$4"
  local cur
  cur=$(defaults read "$domain" "$key" 2>/dev/null) || cur=""
  if [ -n "$cur" ] && _same_default "$typ" "$val" "$cur"; then
    say "  already: ${domain} ${key} = ${val}"
    ALREADY=$((ALREADY + 1))
    return 0
  fi
  if defaults write "$domain" "$key" "$typ" "$val"; then
    say "  set:     ${domain} ${key} ${typ} ${val}"
    CHANGED=$((CHANGED + 1))
    return 0
  fi
  say "  failed:  ${domain} ${key} (left unchanged)"
  FAILED=$((FAILED + 1))
  return 1
}

# A LaunchAgent/Daemon plist exists somewhere we can read (SIP allows reads).
label_plist_exists() {
  local label="$1"
  local d
  for d in \
    /System/Library/LaunchAgents \
    /System/Library/LaunchDaemons \
    /Library/LaunchAgents \
    /Library/LaunchDaemons \
    "${CONSOLE_HOME}/Library/LaunchAgents"
  do
    if [ -f "${d}/${label}.plist" ]; then
      return 0
    fi
  done
  return 1
}

_is_disabled() {
  local domain="$1" label="$2"
  launchctl print-disabled "$domain" 2>/dev/null | grep -F "\"${label}\"" | grep -q 'true'
}

# Disable a user-domain agent if its plist exists. SIP may still refuse
# some labels; those are skipped, not treated as a hard failure.
disable_gui_label() {
  local label="$1"
  if ! label_plist_exists "$label"; then
    say "  skipped: ${label} (no plist on this macOS)"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if _is_disabled "$GUI_DOMAIN" "$label"; then
    say "  already: launchctl disable ${GUI_DOMAIN}/${label}"
    ALREADY=$((ALREADY + 1))
  else
    if launchctl disable "${GUI_DOMAIN}/${label}" 2>/dev/null; then
      say "  set:     launchctl disable ${GUI_DOMAIN}/${label}"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: ${label} (launchctl disable refused; often SIP)"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
  fi
  # Stop it for this session if it is loaded. Ignore a "not loaded" error.
  launchctl bootout "${GUI_DOMAIN}/${label}" >/dev/null 2>&1 || true
  return 0
}

enable_gui_label() {
  local label="$1"
  if ! label_plist_exists "$label"; then
    say "  skipped: ${label} (no plist on this macOS)"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  if _is_disabled "$GUI_DOMAIN" "$label"; then
    if launchctl enable "${GUI_DOMAIN}/${label}" 2>/dev/null; then
      say "  set:     launchctl enable ${GUI_DOMAIN}/${label}"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: ${label} (launchctl enable refused)"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
  else
    say "  already: ${label} is not disabled"
    ALREADY=$((ALREADY + 1))
  fi
  # Kick it so a revert takes effect without logging out. May no-op.
  launchctl kickstart -k "${GUI_DOMAIN}/${label}" >/dev/null 2>&1 || true
  return 0
}

# Apply or revert a list of gui-domain labels (one label per argument).
apply_gui_labels() {
  local label
  for label in "$@"; do
    if [ "$REVERT" -eq 1 ]; then
      enable_gui_label "$label"
    else
      disable_gui_label "$label"
    fi
  done
}

# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

section_spotlight() {
  say ""
  say "== Spotlight indexing =="
  say "   mdutil -a -i off stops metadata indexing (heavy on TCG)."
  local want="off"
  [ "$REVERT" -eq 1 ] && want="on"
  # mdutil prints a per-volume line; a second run is safe.
  if mdutil -a -i "$want" >/tmp/macos-kvm-mdutil.out 2>/tmp/macos-kvm-mdutil.err; then
    say "  set:     mdutil -a -i ${want}"
    CHANGED=$((CHANGED + 1))
  else
    # Some system volumes refuse this under SIP; others still accept it.
    say "  skipped: mdutil -a -i ${want} (some volumes may be SIP-protected)"
    if [ -s /tmp/macos-kvm-mdutil.err ]; then
      sed 's/^/            /' /tmp/macos-kvm-mdutil.err
    fi
    SKIPPED=$((SKIPPED + 1))
  fi
  rm -f /tmp/macos-kvm-mdutil.out /tmp/macos-kvm-mdutil.err
}

section_motion() {
  say ""
  say "== Motion, transparency, window / Dock / Finder animations =="
  if [ "$REVERT" -eq 1 ]; then
    user_defaults_write com.apple.universalaccess reduceMotion -bool false
    user_defaults_write com.apple.universalaccess reduceTransparency -bool false
    user_defaults_write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool true
    user_defaults_delete NSGlobalDomain NSWindowResizeTime
    user_defaults_write com.apple.dock launchanim -bool true
    user_defaults_delete com.apple.dock autohide-delay
    user_defaults_delete com.apple.dock autohide-time-modifier
    user_defaults_delete com.apple.dock expose-animation-duration
    user_defaults_write com.apple.dock mineffect -string genie
    user_defaults_delete com.apple.finder DisableAllAnimations
  else
    user_defaults_write com.apple.universalaccess reduceMotion -bool true
    user_defaults_write com.apple.universalaccess reduceTransparency -bool true
    user_defaults_write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
    user_defaults_write NSGlobalDomain NSWindowResizeTime -float 0.001
    user_defaults_write com.apple.dock launchanim -bool false
    # autohide delay 0: if the user later enables autohide, it is instant
    user_defaults_write com.apple.dock autohide-delay -float 0
    user_defaults_write com.apple.dock autohide-time-modifier -float 0
    user_defaults_write com.apple.dock expose-animation-duration -float 0
    user_defaults_write com.apple.dock mineffect -string scale
    user_defaults_write com.apple.finder DisableAllAnimations -bool true
  fi
}

section_siri() {
  say ""
  say "== Siri, Siri analytics, and suggestions =="
  if [ "$REVERT" -eq 1 ]; then
    user_defaults_write com.apple.assistant.support "Assistant Enabled" -bool true
    user_defaults_write com.apple.Siri StatusMenuVisible -bool true
    user_defaults_write com.apple.Siri VoiceTriggerUserEnabled -bool true
    user_defaults_delete com.apple.Siri LockscreenEnabled
    user_defaults_delete com.apple.assistant.support "Siri Data Sharing Opt-In Status"
    user_defaults_delete com.apple.suggestions SuggestionsEnabled
    user_defaults_delete com.apple.lookup.shared LookupSuggestionsDisabled
    user_defaults_delete com.apple.SetupAssistant DidSeeSiriSetup
  else
    user_defaults_write com.apple.assistant.support "Assistant Enabled" -bool false
    user_defaults_write com.apple.Siri StatusMenuVisible -bool false
    user_defaults_write com.apple.Siri VoiceTriggerUserEnabled -bool false
    user_defaults_write com.apple.Siri LockscreenEnabled -bool false
    # 2 = do not share audio with Apple to improve Siri & Dictation
    user_defaults_write com.apple.assistant.support "Siri Data Sharing Opt-In Status" -int 2
    # Location-based / Spotlight / Look Up suggestions (not Location Services itself)
    user_defaults_write com.apple.suggestions SuggestionsEnabled -bool false
    user_defaults_write com.apple.lookup.shared LookupSuggestionsDisabled -bool true
    user_defaults_write com.apple.SetupAssistant DidSeeSiriSetup -bool true
  fi
  apply_gui_labels \
    com.apple.Siri.agent \
    com.apple.siri.context.service \
    com.apple.siriactionsd \
    com.apple.assistant_service
}

section_timemachine() {
  say ""
  say "== Time Machine automatic backups and local snapshots =="
  if [ "$REVERT" -eq 1 ]; then
    if tmutil enable 2>/dev/null; then
      say "  set:     tmutil enable"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: tmutil enable (no destination or not supported)"
      SKIPPED=$((SKIPPED + 1))
    fi
    root_defaults_write /Library/Preferences/com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool false
  else
    if tmutil disable 2>/dev/null; then
      say "  set:     tmutil disable"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: tmutil disable"
      SKIPPED=$((SKIPPED + 1))
    fi
    # disablelocal was removed after High Sierra; try and ignore failure.
    if tmutil disablelocal >/dev/null 2>&1; then
      say "  set:     tmutil disablelocal"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: tmutil disablelocal (not on this macOS)"
      SKIPPED=$((SKIPPED + 1))
    fi
    root_defaults_write /Library/Preferences/com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true
    # Free space taken by existing local snapshots. Cannot be reverted.
    if tmutil thinlocalsnapshots / 999999999999999 4 >/dev/null 2>&1; then
      say "  set:     tmutil thinlocalsnapshots / (existing local snapshots thinned)"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: tmutil thinlocalsnapshots"
      SKIPPED=$((SKIPPED + 1))
    fi
  fi
}

section_softwareupdate() {
  say ""
  say "== Automatic software update check and download =="
  say "   Manual Software Update still works; the daemon is left enabled."
  if [ "$REVERT" -eq 1 ]; then
    softwareupdate --schedule on >/dev/null 2>&1 || true
    say "  set:     softwareupdate --schedule on"
    CHANGED=$((CHANGED + 1))
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true
    root_defaults_write /Library/Preferences/com.apple.commerce AutoUpdate -bool true
  else
    if softwareupdate --schedule off >/dev/null 2>&1; then
      say "  set:     softwareupdate --schedule off"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: softwareupdate --schedule off (removed on some releases)"
      SKIPPED=$((SKIPPED + 1))
    fi
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
    root_defaults_write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool false
    root_defaults_write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
  fi
}

section_photos() {
  say ""
  say "== Photos / media analysis =="
  apply_gui_labels \
    com.apple.photoanalysisd \
    com.apple.mediaanalysisd \
    com.apple.mediaanalysisd-access
}

section_background_agents() {
  say ""
  say "== Game Center, AirPlay receiver, Handoff (defaults + safe agents) =="
  # rapportd / identityservicesd / sharingd are left alone; they are
  # easy to regret. AirPlay receiver and Handoff are switched off in
  # preferences instead.
  if [ "$REVERT" -eq 1 ]; then
    user_defaults_write com.apple.gamed Disabled -bool false
    user_defaults_host_write com.apple.controlcenter AirplayRecieverEnabled -int 1
    user_defaults_host_write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool true
    user_defaults_host_write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool true
  else
    user_defaults_write com.apple.gamed Disabled -bool true
    # Apple's key is historically misspelled "Reciever".
    user_defaults_host_write com.apple.controlcenter AirplayRecieverEnabled -int 0
    user_defaults_host_write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false
    user_defaults_host_write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false
  fi
  apply_gui_labels \
    com.apple.gamed \
    com.apple.GamePolicyAgent \
    com.apple.amp.mediasharingd
}

section_appleid_icloud_appstore() {
  say ""
  say "== App Store, iCloud, and Apple ID background agents =="
  say "   akd (AuthKit), identityservicesd, and nsurlsessiond are not touched."
  # followupd is what keeps asking to sign in with an Apple ID.
  apply_gui_labels \
    com.apple.storeaccountd \
    com.apple.appstoreagent \
    com.apple.storedownloadd \
    com.apple.commerce \
    com.apple.cloudd \
    com.apple.bird \
    com.apple.icloudmailagent \
    com.apple.iCloudNotificationAgent \
    com.apple.icloudnotificationd \
    com.apple.iCloudUserNotifications \
    com.apple.icloud.searchpartyuseragent \
    com.apple.icloud.findmydeviced.findmydevice-user-agent \
    com.apple.cloudphotod \
    com.apple.security.cloudkeychainproxy3 \
    com.apple.followupd

  local ver
  ver=$(sw_vers -productVersion 2>/dev/null || echo "")
  if [ "$REVERT" -eq 1 ]; then
    user_defaults_write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool true
    user_defaults_delete com.apple.SetupAssistant DidSeeCloudSetup
    user_defaults_delete com.apple.SetupAssistant LastSeenCloudProductVersion
  else
    # Do not offer to save new documents to iCloud.
    user_defaults_write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
    # Mark iCloud Setup Assistant as already seen so it is less likely
    # to come back after first login. The Apple ID pane itself can be
    # skipped in Setup Assistant with "Set Up Later".
    user_defaults_write com.apple.SetupAssistant DidSeeCloudSetup -bool true
    if [ -n "$ver" ]; then
      user_defaults_write com.apple.SetupAssistant LastSeenCloudProductVersion -string "$ver"
    fi
  fi
}

section_analytics_ads() {
  say ""
  say "== Diagnostics, analytics, and personalized ads =="
  if [ "$REVERT" -eq 1 ]; then
    root_defaults_write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist AutoSubmit -bool true
    root_defaults_write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist ThirdPartyDataSubmit -bool true
    root_defaults_write /Library/Preferences/com.apple.SubmitDiagInfo AutoSubmit -bool true
    user_defaults_write com.apple.AdLib allowApplePersonalizedAdvertising -bool true
    user_defaults_write com.apple.AdLib allowIdentifierForAdvertising -bool true
    user_defaults_write com.apple.AdLib forceLimitAdTracking -bool false
    user_defaults_delete com.apple.CrashReporter DialogType
  else
    root_defaults_write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist AutoSubmit -bool false
    root_defaults_write /Library/Application\ Support/CrashReporter/DiagnosticMessagesHistory.plist ThirdPartyDataSubmit -bool false
    root_defaults_write /Library/Preferences/com.apple.SubmitDiagInfo AutoSubmit -bool false
    user_defaults_write com.apple.AdLib allowApplePersonalizedAdvertising -bool false
    user_defaults_write com.apple.AdLib allowIdentifierForAdvertising -bool false
    user_defaults_write com.apple.AdLib forceLimitAdTracking -bool true
    # Hide the crash-report dialog (reports can still be found in Console).
    user_defaults_write com.apple.CrashReporter DialogType -string none
  fi
  apply_gui_labels \
    com.apple.ReportCrash \
    com.apple.ReportPanic \
    com.apple.DiagnosticReportCleanup \
    com.apple.SubmitDiagInfo \
    com.apple.ap.adprivacyd \
    com.apple.ap.adservicesd \
    com.apple.ap.promotedcontentd
}

section_power() {
  say ""
  say "== Sleep, display sleep, hibernation, sudden motion, low power =="
  # pmset -a applies to battery and charger; a VM usually has only AC.
  if [ "$REVERT" -eq 1 ]; then
    pmset -a displaysleep 10 sleep 10 disksleep 10
    pmset -a hibernatemode 0
    pmset -a autopoweroff 1 standby 1
    pmset -a powernap 1
    pmset -a proximitywake 1
    pmset -a tcpkeepalive 1
    pmset -a sms 1 2>/dev/null || true
    pmset -a ttyskeepawake 1
    say "  set:     pmset displaysleep/sleep/disksleep 10, hibernatemode 0,"
    say "           autopoweroff/standby/powernap/proximitywake/tcpkeepalive on"
    CHANGED=$((CHANGED + 1))
    user_defaults_host_write com.apple.screensaver idleTime -int 1200
  else
    # Keep the display awake so the VNC viewer does not go black.
    pmset -a displaysleep 0 sleep 0 disksleep 0
    pmset -a hibernatemode 0
    pmset -a autopoweroff 0 standby 0
    pmset -a powernap 0
    pmset -a proximitywake 0
    # No need for Apple push keep-alives in a guest with no Apple ID.
    pmset -a tcpkeepalive 0
    # Sudden motion sensor: no-op on most VMs, harmless if absent.
    if pmset -a sms 0 2>/dev/null; then
      say "  set:     pmset sms 0"
      CHANGED=$((CHANGED + 1))
    else
      say "  skipped: pmset sms (not present)"
      SKIPPED=$((SKIPPED + 1))
    fi
    pmset -a ttyskeepawake 1
    say "  set:     pmset displaysleep/sleep/disksleep 0, hibernatemode 0,"
    say "           autopoweroff/standby/powernap/proximitywake/tcpkeepalive off,"
    say "           ttyskeepawake on"
    CHANGED=$((CHANGED + 1))
    user_defaults_host_write com.apple.screensaver idleTime -int 0
  fi
}

section_dock() {
  [ "$CLEAR_DOCK" -eq 1 ] || return 0
  say ""
  say "== Dock shortcuts =="
  if [ "$REVERT" -eq 1 ]; then
    if [ -f "$DOCK_BACKUP" ]; then
      if as_user defaults import com.apple.dock "$DOCK_BACKUP"; then
        say "  set:     restored Dock from ${DOCK_BACKUP}"
        CHANGED=$((CHANGED + 1))
      else
        say "  failed:  could not import ${DOCK_BACKUP}"
        FAILED=$((FAILED + 1))
      fi
    else
      say "  skipped: no Dock backup at ${DOCK_BACKUP}"
      SKIPPED=$((SKIPPED + 1))
    fi
    return 0
  fi
  if [ ! -f "$DOCK_BACKUP" ]; then
    if as_user defaults export com.apple.dock "$DOCK_BACKUP"; then
      chown "${CONSOLE_USER}" "$DOCK_BACKUP" 2>/dev/null || true
      say "  set:     saved current Dock to ${DOCK_BACKUP}"
      CHANGED=$((CHANGED + 1))
    else
      say "  failed:  could not save the Dock; leaving it unchanged"
      FAILED=$((FAILED + 1))
      return 1
    fi
  else
    say "  already: Dock backup exists at ${DOCK_BACKUP} (not overwritten)"
    ALREADY=$((ALREADY + 1))
  fi
  # Empty persistent apps / folders. Finder and Trash are not stored
  # in persistent-apps, so they stay. Array defaults are written
  # directly; the usual key/value compare does not fit them.
  if as_user defaults write com.apple.dock persistent-apps -array \
     && as_user defaults write com.apple.dock persistent-others -array; then
    say "  set:     cleared persistent-apps and persistent-others on the Dock"
    CHANGED=$((CHANGED + 1))
  else
    say "  failed:  could not clear the Dock"
    FAILED=$((FAILED + 1))
  fi
}

restart_ui() {
  say ""
  say "== Restarting Dock, Finder, and SystemUIServer for this user =="
  # These are UI processes; killing them does not log you out.
  sudo -u "$CONSOLE_USER" killall Dock >/dev/null 2>&1 || true
  sudo -u "$CONSOLE_USER" killall Finder >/dev/null 2>&1 || true
  sudo -u "$CONSOLE_USER" killall SystemUIServer >/dev/null 2>&1 || true
  say "  set:     sent Dock, Finder, SystemUIServer a restart"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

say "macOS guest debloat (SIP stays on; no /System changes)"
say "  user:    ${CONSOLE_USER} (uid ${CONSOLE_UID})"
say "  home:    ${CONSOLE_HOME}"
if [ "$REVERT" -eq 1 ]; then
  say "  mode:    revert to typical macOS defaults"
else
  say "  mode:    apply TCG-friendly debloat"
fi
if [ "$CLEAR_DOCK" -eq 1 ]; then
  say "  dock:    --clear-dock is on"
fi

section_spotlight
section_motion
section_siri
section_timemachine
section_softwareupdate
section_photos
section_background_agents
section_appleid_icloud_appstore
section_analytics_ads
section_power
section_dock
restart_ui

say ""
say "Done. changed=${CHANGED} already=${ALREADY} skipped=${SKIPPED} failed=${FAILED}"
if [ "$REVERT" -eq 0 ]; then
  say "Re-run with --revert to put typical macOS defaults back."
  say "Some skipped items are normal: the label is missing, or SIP refused it."
fi
if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
exit 0
