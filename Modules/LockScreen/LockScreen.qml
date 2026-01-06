import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pam
import Quickshell.Services.UPower
import Quickshell.Wayland
import qs.Commons
import qs.Services.Compositor
import qs.Services.Hardware
import qs.Services.Keyboard
import qs.Services.Media
import qs.Services.UI
import qs.Widgets

Loader {
  id: root
  active: false

  // Track if the visualizer should be shown (lockscreen active + media playing + non-compact mode)
  readonly property bool needsCava: root.active && !Settings.data.general.compactLockScreen && Settings.data.audio.visualizerType !== "" && Settings.data.audio.visualizerType !== "none"

  onActiveChanged: {
    if (root.active && root.needsCava) {
      CavaService.registerComponent("lockscreen");
    } else {
      CavaService.unregisterComponent("lockscreen");
    }
  }

  onNeedsCavaChanged: {
    if (root.needsCava) {
      CavaService.registerComponent("lockscreen");
    } else {
      CavaService.unregisterComponent("lockscreen");
    }
  }

  Component.onCompleted: {
    // Register with panel service
    PanelService.lockScreen = this;
  }

  Timer {
    id: unloadAfterUnlockTimer
    interval: 250
    repeat: false
    onTriggered: root.active = false
  }

  function scheduleUnloadAfterUnlock() {
    unloadAfterUnlockTimer.start();
  }

  sourceComponent: Component {
    Item {
      id: lockContainer

      LockContext {
        id: lockContext
        onUnlocked: {
          lockSession.locked = false;
          root.scheduleUnloadAfterUnlock();
          lockContext.currentText = "";
        }
        onFailed: {
          lockContext.currentText = "";
        }
      }

      WlSessionLock {
        id: lockSession
        locked: root.active

        WlSessionLockSurface {
          id: lockSurface

          Item {
            id: batteryIndicator
            property bool initializationComplete: false
            Timer {
              interval: 500
              running: true
              onTriggered: batteryIndicator.initializationComplete = true
            }

            property bool isReady: initializationComplete && BatteryService.batteryReady
            property real percent: BatteryService.batteryPercentage
            property bool charging: BatteryService.batteryCharging
            property bool batteryVisible: isReady && percent > 0 && BatteryService.hasAnyBattery()
          }

          Item {
            id: keyboardLayout
            property string currentLayout: KeyboardLayoutService.currentLayout
          }

          // Background with wallpaper, gradient, and screen corners
          LockScreenBackground {
            id: backgroundComponent
            screen: lockSurface.screen
          }

          Item {
            anchors.fill: parent
            focus: true

            // Key handler - forward to fingerprint layer first
            Keys.onPressed: function (event) {
              if (fingerprintAuthLayer.handleKeyPress(event)) {
                event.accepted = true;
                return;
              }
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                lockContext.tryUnlock();
                event.accepted = true;
              }
            }

            // Mouse area to trigger focus on cursor movement (workaround for Hyprland focus issues)
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
              onPositionChanged: {
                if (passwordInput) {
                  passwordInput.forceActiveFocus();
                }
              }
              onClicked: {
                if (!fingerprintAuthLayer.handleClick() && passwordInput) {
                  passwordInput.forceActiveFocus();
                }
              }
            }

            // Fingerprint authentication layer (shield + indicator)
            // This component is isolated to minimize upstream merge conflicts
            FingerprintAuthLayer {
              id: fingerprintAuthLayer
              lockContext: lockContext
              visible: Settings.data.general.fingerprintEnabled && FingerprintService.available
            }

            // Header with avatar, welcome, time, date
            LockScreenHeader {
              id: headerComponent
              visible: !fingerprintAuthLayer.shieldActive
            }

            // Info notification
            Rectangle {
              width: infoRowLayout.implicitWidth + Style.marginXL * 1.5
              height: 50
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: (Settings.data.general.compactLockScreen ? 280 : 360) * Style.uiScaleRatio
              radius: Style.radiusL
              color: Color.mTertiary
              border.color: Color.mTertiary
              border.width: Style.borderS
              visible: !fingerprintAuthLayer.shieldActive && lockContext.showInfo && lockContext.infoMessage
              opacity: visible ? 1.0 : 0.0

              RowLayout {
                id: infoRowLayout
                anchors.centerIn: parent
                spacing: Style.marginM

                NIcon {
                  icon: "circle-key"
                  pointSize: Style.fontSizeXL
                  color: Color.mOnTertiary
                }

                NText {
                  text: lockContext.infoMessage
                  color: Color.mOnTertiary
                  pointSize: Style.fontSizeL
                  horizontalAlignment: Text.AlignHCenter
                }
              }

              Behavior on opacity {
                NumberAnimation {
                  duration: Style.animationNormal
                  easing.type: Easing.OutCubic
                }
              }
            }

            // Error notification
            Rectangle {
              width: errorRowLayout.implicitWidth + Style.marginXL * 1.5
              height: 50
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: (Settings.data.general.compactLockScreen ? 280 : 360) * Style.uiScaleRatio
              radius: Style.radiusL
              color: Color.mError
              border.color: Color.mError
              border.width: Style.borderS
              visible: !fingerprintAuthLayer.shieldActive && lockContext.showFailure && lockContext.errorMessage
              opacity: visible ? 1.0 : 0.0

              RowLayout {
                id: errorRowLayout
                anchors.centerIn: parent
                spacing: Style.marginM

                NIcon {
                  icon: "alert-circle"
                  pointSize: Style.fontSizeXL
                  color: Color.mOnError
                }

                NText {
                  text: lockContext.errorMessage || "Authentication failed"
                  color: Color.mOnError
                  pointSize: Style.fontSizeL
                  horizontalAlignment: Text.AlignHCenter
                }
              }

              Behavior on opacity {
                NumberAnimation {
                  duration: Style.animationNormal
                  easing.type: Easing.OutCubic
                }
              }
            }

            // Hidden text input for password capture
            TextInput {
              id: passwordInput
              visible: false
              echoMode: TextInput.Password
              passwordCharacter: "•"
              passwordMaskDelay: 0
              text: lockContext.currentText
              onTextChanged: lockContext.currentText = text

              Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  lockContext.tryUnlock();
                }
              }

              Component.onCompleted: forceActiveFocus()
            }

            // Main panel with password, weather, media, session controls
            LockScreenPanel {
              id: panelComponent
              lockControl: lockContext
              batteryIndicator: batteryIndicator
              keyboardLayout: keyboardLayout
              passwordInput: passwordInput
              visible: !fingerprintAuthLayer.shieldActive
            }
          }

          // Reset state when lock screen activates
          Connections {
            target: lockSession
            function onLockedChanged() {
              if (lockSession.locked) {
                lockContext.resetForNewSession();
                fingerprintAuthLayer.reset();
              }
            }
          }
        }
      }
    }
  }
}
