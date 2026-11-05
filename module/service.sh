#!/system/bin/sh
# Started late at boot. The Kotlin control daemon does the real work — it harvests
# the device's attestation parameters, resolves config.json into per-profile
# settings, injects the interceptor into keystore/keystore2, and pushes the resolved
# config over the control socket, re-injecting and re-pushing as things change. This
# script only launches the daemon and respawns it if it ever exits.
MODDIR=${0%/*}

# admin.token is the WebUI's key-management credential; keep it root-only. The whole data dir holds
# the token and the admin socket, so keep it 0700 too — the socket is then unreachable to other apps.
chmod 0700 /data/adb/teesim 2>/dev/null
chmod 0600 /data/adb/teesim/admin.token 2>/dev/null

# Stage the WebUI's admin-socket client at a fixed, root-only path, so the WebUI can invoke it without
# knowing the module's runtime path or the device ABI. Only the device's own ABI dir survives install,
# so the glob matches one file; refreshed every boot so a module update always stages the current one.
for f in "$MODDIR"/*/teesim-uds; do
  if [ -f "$f" ]; then
    cp "$f" /data/adb/teesim/teesim-uds && chmod 0700 /data/adb/teesim/teesim-uds
    break
  fi
done

# MIUI/HyperOS ThemeCompatibility crash guard (seen on MI9 / MIUI Android 11): the MIUI resource
# layer hardcodes /data/system/theme_config/theme_compatibility.xml, and when that file is missing
# the daemon's first Resources.getSystem() call (ConfigManager.openDb -> SQLiteGlobal ->
# MiuiResources -> ThemeCompatibility.<clinit>) dies with FileNotFoundException: ENOENT, so the
# daemon crash-loops before it ever injects. The file ships in the system theme dir; stage a copy
# into /data/system/theme_config before the daemon starts.
THEME_CONFIG_DIR=/data/system/theme_config
THEME_CONFIG_XML=$THEME_CONFIG_DIR/theme_compatibility.xml
if [ ! -f "$THEME_CONFIG_XML" ]; then
  for THEME_SRC in /system/media/theme/theme_compatibility.xml /product/media/theme/theme_compatibility.xml; do
    if [ -f "$THEME_SRC" ]; then
      mkdir -p "$THEME_CONFIG_DIR" 2>/dev/null
      cp "$THEME_SRC" "$THEME_CONFIG_XML" 2>/dev/null &&
        chown system:system "$THEME_CONFIG_DIR" "$THEME_CONFIG_XML" 2>/dev/null
      chmod 770 "$THEME_CONFIG_DIR" 2>/dev/null
      chmod 660 "$THEME_CONFIG_XML" 2>/dev/null
      echo "teesim: staged theme_compatibility.xml from $THEME_SRC"
      break
    fi
  done
fi

while true; do
  "$MODDIR/daemon" "$MODDIR"
  sleep 2
done &
