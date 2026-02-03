import QtQuick
import Quickshell

QtObject {
  id: root

  function migrate(adapter, logger, rawJson) {
    logger.i("Migration46", "Removing legacy password.conf PAM config");

    const shellName = "noctalia";
    const configDir = Quickshell.env("NOCTALIA_CONFIG_DIR") || (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/" + shellName + "/";
    const pamConfigFile = configDir + "pam/password.conf";
    Quickshell.execDetached(["rm", "-f", pamConfigFile]);

    logger.d("Migration46", "Removed legacy PAM config: " + pamConfigFile);

    return true;
  }
}
