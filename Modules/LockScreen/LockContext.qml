import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.Commons
import qs.Services.Hardware
import qs.Services.System

Scope {
  id: root
  signal unlocked
  signal failed
  signal fingerprintFailed  // Emitted on each fingerprint match failure

  property string currentText: ""
  property bool waitingForPassword: false
  property bool unlockInProgress: false
  property bool showFailure: false
  property bool showInfo: false
  property string errorMessage: ""
  property string infoMessage: ""
  property bool pamAvailable: typeof PamContext !== "undefined"

  // Fingerprint authentication properties
  readonly property bool fingerprintMode: FingerprintService.ready
  property bool pamStarted: false // Track if PAM session started for this lock
  property bool usePasswordOnly: false // True when user typed password during fingerprint scan
  property bool abortInProgress: false // True when aborting fingerprint to switch to password

  // Computed property for fingerprint indicator visibility
  // Keep showing while typing - only hide when Enter pressed (switches to password mode)
  readonly property bool showFingerprintIndicator: fingerprintMode && unlockInProgress && !waitingForPassword && !showFailure && !usePasswordOnly

  // PAM config:
  // If NOCTALIA_PAM_CONFIG env var is set, use system config (for NixOS module integration)
  // Otherwise: use our generated configs in ~/.config/noctalia/pam/
  readonly property string pamConfigDirectory: Quickshell.env("NOCTALIA_PAM_CONFIG") ? "/etc/pam.d" : Settings.configDir + "pam"
  readonly property string pamConfig: {
    // Env var override takes precedence (NixOS users set this via module)
    if (Quickshell.env("NOCTALIA_PAM_CONFIG")) {
      return Quickshell.env("NOCTALIA_PAM_CONFIG");
    }
    // Use our generated configs
    return (usePasswordOnly || !fingerprintMode) ? "password-only.conf" : "fingerprint-only.conf";
  }

  onCurrentTextChanged: {
    if (currentText !== "") {
      showInfo = false;
      infoMessage = "";
      showFailure = false;
      errorMessage = "";
    }
  }

  // Reset state for a new lock session
  function resetForNewSession() {
    Logger.i("LockContext", "Resetting state for new lock session");
    abortTimer.stop();
    fingerprintRestartTimer.stop();
    pamStarted = false;
    waitingForPassword = false;
    usePasswordOnly = false;
    abortInProgress = false;
    showFailure = false;
    errorMessage = "";
    infoMessage = "";
    currentText = "";
  }

  // Timeout for PAM abort operation
  Timer {
    id: abortTimer
    interval: 150 // 150ms timeout (reduced from 500ms for better UX)
    repeat: false
    onTriggered: {
      if (root.abortInProgress) {
        Logger.i("LockContext", "PAM abort timeout, forcing state reset");
        root.abortInProgress = false;
        root.unlockInProgress = false;
        root.usePasswordOnly = true;
        root.pamStarted = false;
        // Retry with password-only
        root.tryUnlock();
      }
    }
  }

  // Delay before restarting fingerprint auth (prevents tight loops on errors)
  Timer {
    id: fingerprintRestartTimer
    interval: 500
    repeat: false
    onTriggered: root.startFingerprintAuth()
  }

  // Start fingerprint authentication when lock screen becomes visible
  // Called from LockScreen.qml when surface becomes visible
  function startFingerprintAuth() {
    Logger.i("LockContext", "startFingerprintAuth called - fingerprintMode:", fingerprintMode, "FingerprintService.ready:", FingerprintService.ready, "FingerprintService.available:", FingerprintService.available, "pamStarted:", pamStarted, "unlockInProgress:", unlockInProgress, "currentText:", currentText !== "" ? "[has text: '" + currentText + "']" :
                                                                                                                                                                                                                                                                                                                            "[empty]");

    if (!fingerprintMode) {
      Logger.d("LockContext", "Fingerprint mode not available, skipping auto-start");
      return;
    }

    if (pamStarted || unlockInProgress) {
      Logger.d("LockContext", "PAM already started, skipping");
      return;
    }

    Logger.i("LockContext", "Starting fingerprint authentication");
    pamStarted = true;
    tryUnlock();
  }

  // fromEnterPress: true when user explicitly pressed Enter to submit password
  function tryUnlock(fromEnterPress) {
    fromEnterPress = fromEnterPress || false;
    Logger.i("LockContext", "tryUnlock called - fromEnterPress:", fromEnterPress, "pamAvailable:", pamAvailable, "waitingForPassword:", waitingForPassword, "currentText:", currentText !== "" ? "[has text]" : "[empty]", "unlockInProgress:", unlockInProgress, "abortInProgress:", abortInProgress);

    if (!pamAvailable) {
      Logger.i("LockContext", "PAM not available, showing error");
      errorMessage = "PAM not available";
      showFailure = true;
      return;
    }

    // If we're waiting for password input and user has typed something, respond
    if (waitingForPassword && currentText !== "") {
      Logger.i("LockContext", "Responding to PAM with password");
      pam.respond(currentText);
      waitingForPassword = false;
      return;
    }

    // If fingerprint is scanning and user explicitly pressed Enter with password,
    // switch to password-only mode (only when using our custom configs, not system config)
    if (fromEnterPress && root.unlockInProgress && currentText !== "" && !waitingForPassword && !abortInProgress && !Quickshell.env("NOCTALIA_PAM_CONFIG")) {
      Logger.i("LockContext", "User pressed Enter during fingerprint scan, switching to password-only mode");
      root.abortInProgress = true;
      abortTimer.start();
      pam.abort();
      // Don't continue - wait for PAM onCompleted/onError or abort timeout
      return;
    }

    if (root.unlockInProgress) {
      Logger.i("LockContext", "Unlock already in progress, ignoring duplicate attempt");
      return;
    }

    root.unlockInProgress = true;
    errorMessage = "";
    showFailure = false;

    Logger.i("LockContext", "Starting PAM authentication:", "user:", pam.user, "configDirectory:", pamConfigDirectory, "config:", pamConfig, "fullPath:", pamConfigDirectory + "/" + pamConfig, "fingerprintMode:", fingerprintMode, "usePasswordOnly:", usePasswordOnly, "NOCTALIA_PAM_CONFIG env:", Quickshell.env("NOCTALIA_PAM_CONFIG") || "[not set]");
    pam.start();
    Logger.i("LockContext", "PAM started, unlockInProgress:", root.unlockInProgress);
  }

  PamContext {
    id: pam
    // Use custom PAM configs for separate fingerprint/password flows
    // fingerprint-only.conf: only pam_fprintd.so (no password fallback)
    // password-only.conf: only pam_unix.so (no fingerprint)
    // Can be overridden with NOCTALIA_PAM_CONFIG env var for system config
    configDirectory: root.pamConfigDirectory
    config: root.pamConfig
    user: HostService.username

    onPamMessage: {
      Logger.i("LockContext", "PAM message:", message, "isError:", messageIsError, "responseRequired:", responseRequired);

      if (messageIsError) {
        errorMessage = message;
        // Detect fingerprint failure and emit signal
        var msgLower = message.toLowerCase();
        if (msgLower.includes("failed") && msgLower.includes("fingerprint")) {
          Logger.i("LockContext", "Fingerprint failure detected, emitting signal");
          root.fingerprintFailed();
        }
      } else {
        infoMessage = message;
      }

      if (this.responseRequired) {
        var msgLower = message.toLowerCase();
        var isFingerprintPrompt = msgLower.includes("finger") || msgLower.includes("swipe") || msgLower.includes("touch") || msgLower.includes("scan");
        Logger.i("LockContext", "Response required, isFingerprintPrompt:", isFingerprintPrompt, "usePasswordOnly:", root.usePasswordOnly, "currentText:", root.currentText !== "" ? "[has text]" : "[empty]");

        if (isFingerprintPrompt) {
          // Fingerprint prompt - don't respond with typed text, let fprintd wait for sensor
          // User can type password in background and press Enter to switch to password mode
          Logger.i("LockContext", "Fingerprint prompt, waiting for finger via sensor (ignoring typed text)");
        } else if (root.currentText !== "") {
          // Password prompt with text - respond with it
          Logger.i("LockContext", "Responding to PAM with password");
          this.respond(root.currentText);
        } else {
          // Password prompt with no text - wait for user input
          Logger.i("LockContext", "Password required, waiting for user input");
          root.waitingForPassword = true;
        }
      }
    }

    onCompleted: result => {
                   var resultName = result === PamResult.Success ? "Success" : result === PamResult.AuthError ? "AuthError" : result === PamResult.CredentialsUnavailable ? "CredentialsUnavailable" : result === PamResult.AccountExpired ? "AccountExpired" : result === PamResult.MaxTries ? "MaxTries" : result === PamResult.PermissionDenied ? "PermissionDenied" :
                                                                                                                                                                                                                                                                                                                                                     "Unknown("
                                                                                                                                                                                                                                                                                                                                                     + result + ")";
                   Logger.i("LockContext", "PAM completed - result:", result, "(" + resultName + ")", "fingerprintMode:", root.fingerprintMode, "usePasswordOnly:", root.usePasswordOnly, "abortInProgress:", root.abortInProgress);

                   // Handle abort completion - restart with password-only
                   if (root.abortInProgress) {
                     Logger.i("LockContext", "PAM aborted, restarting with password-only config");
                     abortTimer.stop();
                     root.abortInProgress = false;
                     root.unlockInProgress = false;
                     root.usePasswordOnly = true;
                     root.pamStarted = false;
                     root.tryUnlock();
                     return;
                   }

                   if (result === PamResult.Success) {
                     Logger.i("LockContext", "Authentication successful");
                     root.unlocked();
                   } else {
                     Logger.i("LockContext", "Authentication failed");
                     root.currentText = "";
                     // Only show error text for password failures, not fingerprint
                     // (fingerprint has the red shaking icon instead)
                     if (root.usePasswordOnly || !root.fingerprintMode) {
                       errorMessage = I18n.tr("authentication.failed");
                       showFailure = true;
                     }
                     root.failed();
                   }
                   root.unlockInProgress = false;
                   root.waitingForPassword = false;
                   root.usePasswordOnly = false;
                   root.pamStarted = false;
                   // Note: No auto-restart on failure - user must dismiss shield or press key to retry
                   // This prevents infinite retry loops when fprintd returns immediately
                 }

    onError: {
      Logger.i("LockContext", "PAM error:", error, "message:", message);

      // Handle abort completion - restart with password-only
      if (root.abortInProgress) {
        Logger.i("LockContext", "PAM abort error, restarting with password-only config");
        abortTimer.stop();
        root.abortInProgress = false;
        root.unlockInProgress = false;
        root.usePasswordOnly = true;
        root.pamStarted = false;
        root.tryUnlock();
        return;
      }

      // Only show error text for password failures, not fingerprint
      // (fingerprint has the red shaking icon instead)
      if (root.usePasswordOnly || !root.fingerprintMode) {
        errorMessage = message || "Authentication error";
        showFailure = true;
      }
      root.unlockInProgress = false;
      root.waitingForPassword = false;
      root.usePasswordOnly = false;
      root.pamStarted = false;
      root.failed();
      // Note: No auto-restart on error - user must dismiss shield or press key to retry
      // This prevents infinite retry loops when fprintd is in a bad state
    }
  }
}
