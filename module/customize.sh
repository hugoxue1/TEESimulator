# Runs at install time under Magisk, KernelSU, or APatch.

# The interceptor is a 64-bit library injected into the keystore daemon, which is 64-bit on every
# supported device; refuse 32-bit-only devices rather than fail silently.
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x64" ]; then
  abort "! TEESimulator requires a 64-bit device"
fi

# TrickyStore intercepts the same keystore path; running both would double-hook it. Disable it via
# its manager's marker (kept, not deleted, so removing us lets the user re-enable it).
for ts in /data/adb/modules/tricky_store /data/adb/modules_update/tricky_store; do
  if [ -d "$ts" ] && [ ! -f "$ts/disable" ]; then
    ui_print "- Disabling TrickyStore (it hooks the same keystore path)"
    touch "$ts/disable"
  fi
done

# Seed the configuration on first install without clobbering existing files.
mkdir -p /data/adb/teesim
# Adopt a keybox the user already set up for TrickyStore when we have none of our own.
if [ ! -f /data/adb/teesim/keybox.xml ] && [ -f /data/adb/tricky_store/keybox.xml ]; then
  ui_print "- Adopting the keybox from TrickyStore"
  cp /data/adb/tricky_store/keybox.xml /data/adb/teesim/keybox.xml
fi
if [ ! -f /data/adb/teesim/config.json ]; then
  cp "$MODPATH/config.default.json" /data/adb/teesim/config.json
fi

# The customised APatch can authorize one exact injector/keystore transaction
# without loading a persistent SELinux policy.  Record that install-time choice
# in the module directory and remove only the installed copy of sepolicy.rule.
# Every other root manager keeps the compatibility policy unchanged.
APATCH_INJECT_MARKER="$MODPATH/.apatch_exact_inject_v1"
SU=/system/bin/su
if [ -x "$SU" ] && "$SU" --no-pty --inject-capable >/dev/null 2>&1; then
  rm -f "$MODPATH/sepolicy.rule"
  : > "$APATCH_INJECT_MARKER"
  ui_print "- Using APatch exact injection (no persistent SELinux policy)"
else
  rm -f "$APATCH_INJECT_MARKER"
fi

# Ship only the ABI this device runs; the other ABI's native libraries are dead weight here.
case "$ARCH" in
  arm64) rm -rf "$MODPATH/x86_64" ;;
  x64) rm -rf "$MODPATH/arm64-v8a" ;;
esac

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/daemon" 0 0 0755
for abi in arm64-v8a x86_64; do
  [ -f "$MODPATH/$abi/inject" ] && set_perm "$MODPATH/$abi/inject" 0 0 0755
done
