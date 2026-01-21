import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Services.Hardware
import qs.Widgets

// Fingerprint authentication UI layer
// Contains shield overlay and fingerprint indicator
// Designed to be composed into LockScreen with minimal coupling
Item {
  id: root
  anchors.fill: parent

  // Required: reference to lock context for signals
  required property var lockContext

  // Exposed state - parent components bind to this for visibility
  // Shield is only "active" (blocking content) when both visible AND internal state is active
  readonly property bool shieldActive: visible && internal.shieldActive

  // Fingerprint indicator visibility (for external queries)
  readonly property bool showingFingerprintIndicator: fingerprintIndicator.visible

  // Dismiss shield and start authentication
  function dismissShield() {
    if (!internal.shieldActive)
      return;
    internal.shieldActive = false;
    // Start fingerprint auth when shield is dismissed
    if (Settings.data.general.fingerprintEnabled && FingerprintService.available) {
      lockContext.startFingerprintAuth();
    }
  }

  // Reset state (called when lock screen activates)
  function reset() {
    internal.shieldActive = true;
    fingerprintShowTimer.shouldShow = false;
    fingerprintIndicator.showingError = false;
  }

  // Internal state
  QtObject {
    id: internal
    property bool shieldActive: true
  }

  // Shield overlay - "Press any key to unlock"
  Rectangle {
    id: shieldOverlay
    anchors.fill: parent
    color: "transparent"
    visible: internal.shieldActive
    z: 100

    // Minimal background pill for visibility on any wallpaper
    Rectangle {
      anchors.centerIn: parent
      width: shieldContent.width + Style.marginL * 2
      height: shieldContent.height + Style.marginM * 2
      radius: Style.radiusL
      color: Qt.alpha(Color.mSurface, 0.7)
    }

    RowLayout {
      id: shieldContent
      anchors.centerIn: parent
      spacing: Style.marginS

      NIcon {
        Layout.alignment: Qt.AlignVCenter
        icon: "lock"
        pointSize: Style.fontSizeL
        color: Color.mOnSurfaceVariant
      }

      NText {
        Layout.alignment: Qt.AlignVCenter
        text: I18n.tr("lock-screen.press-to-unlock")
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeM
      }
    }

    Behavior on opacity {
      NumberAnimation {
        duration: Style.animationNormal
        easing.type: Easing.OutCubic
      }
    }
  }

  // Fingerprint status indicator (icon only, with failure animation)
  Rectangle {
    id: fingerprintIndicator
    width: 50
    height: 50
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: (Settings.data.general.compactLockScreen ? 340 : 420) * Style.uiScaleRatio
    radius: width / 2
    // Use hardcoded red for error to ensure visibility in all color schemes (including monochrome)
    color: showingError ? Qt.alpha("#F44336", 0.25) : Color.mSurfaceVariant
    border.color: showingError ? "#F44336" : Qt.alpha(Color.mPrimary, 0.3)
    border.width: showingError ? 2 : 1
    visible: !internal.shieldActive && (fingerprintShowTimer.shouldShow || FingerprintService.systemPamMode)
    opacity: visible ? 1.0 : 0.0

    property bool showingError: false

    NIcon {
      id: fingerprintIcon
      anchors.centerIn: parent
      icon: "fingerprint"
      pointSize: Style.fontSizeXXL
      color: fingerprintIndicator.showingError ? "#F44336" : Color.mPrimary

      Behavior on color {
        ColorAnimation {
          duration: 150
        }
      }
    }

    // Shake animation on error
    SequentialAnimation {
      id: shakeAnimation
      PropertyAnimation {
        target: fingerprintIndicator
        property: "x"
        to: fingerprintIndicator.x - 10
        duration: 50
      }
      PropertyAnimation {
        target: fingerprintIndicator
        property: "x"
        to: fingerprintIndicator.x + 10
        duration: 50
      }
      PropertyAnimation {
        target: fingerprintIndicator
        property: "x"
        to: fingerprintIndicator.x - 10
        duration: 50
      }
      PropertyAnimation {
        target: fingerprintIndicator
        property: "x"
        to: fingerprintIndicator.x
        duration: 50
      }
    }

    // Timer to show fingerprint indicator after a brief delay
    Timer {
      id: fingerprintShowTimer
      interval: 500
      running: !internal.shieldActive && Settings.data.general.fingerprintEnabled && (FingerprintService.available || FingerprintService.systemPamMode)
      property bool shouldShow: false
      onTriggered: shouldShow = true
    }

    // Listen for fingerprint errors
    Connections {
      target: root.lockContext
      function onFingerprintFailed() {
        fingerprintIndicator.showingError = true;
        shakeAnimation.start();
        fingerprintErrorResetTimer.start();
      }
    }

    Timer {
      id: fingerprintErrorResetTimer
      interval: 1500
      onTriggered: fingerprintIndicator.showingError = false
    }

    Behavior on opacity {
      NumberAnimation {
        duration: Style.animationNormal
        easing.type: Easing.OutCubic
      }
    }
  }

  // Key handler - parent should forward key events or use Keys.forwardTo
  // Returns true if event should be consumed (non-printable keys), false if it should pass through (printable chars)
  function handleKeyPress(event) {
    if (internal.shieldActive) {
      dismissShield();
      // Printable characters should pass through to password input
      // Check if it's a printable character (has text and not a modifier/special key)
      if (event.text && event.text.length > 0) {
        return false; // don't consume - let it reach password input
      }
      return true; // consume non-printable keys (Enter, arrows, etc.)
    }
    return false; // not consumed
  }

  // Mouse click handler - parent should call this from MouseArea
  function handleClick() {
    if (internal.shieldActive) {
      dismissShield();
      return true; // consumed
    }
    return false; // not consumed
  }
}
