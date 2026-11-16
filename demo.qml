import QtQuick
import QtQuick.Layouts
import MuseScore 3.0
import Muse.Ui
import Muse.UiComponents as MU

MuseScore {
    id: helloDemo
    title: "Hello Score Demo"
    description: "Sample UI & breakpoint demo for Plugin Creator"
    version: "1.0"
    pluginType: "dialog"

    implicitWidth: 320
    implicitHeight: 190

    property int transposeSteps: 2
    property string greetingText: "Ready to transpose!"

    onRun: {
        console.log("Hello Score Demo initialized")
        var summary = formatGreeting(transposeSteps)
        greetingText = summary
        console.log("Status:", summary)
    }

    function formatGreeting(semitones) {
        var direction = semitones >= 0 ? "up" : "down"
        var label = "Hello Score! Shift " + direction + " by " + Math.abs(semitones) + " semitones"
        return label
    }

    Rectangle {
        anchors.fill: parent
        color: ui.theme.backgroundSecondaryColor

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 16
            spacing: 10

            MU.StyledTextLabel {
                text: "Hello Score — Demo Plugin"
                font.pixelSize: 15
                font.bold: true
            }

            MU.StyledTextLabel {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: helloDemo.greetingText
                opacity: 0.85
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                MU.StyledTextLabel { text: "Semitones:" }

                MU.FlatButton {
                    text: "-1"
                    onClicked: {
                        helloDemo.transposeSteps--
                        helloDemo.greetingText = helloDemo.formatGreeting(helloDemo.transposeSteps)
                    }
                }

                MU.StyledTextLabel {
                    text: (helloDemo.transposeSteps >= 0 ? "+" : "") + helloDemo.transposeSteps
                    font.bold: true
                }

                MU.FlatButton {
                    text: "+1"
                    onClicked: {
                        helloDemo.transposeSteps++
                        helloDemo.greetingText = helloDemo.formatGreeting(helloDemo.transposeSteps)
                    }
                }
            }

            Item { Layout.fillHeight: true }

            MU.FlatButton {
                Layout.alignment: Qt.AlignRight
                text: "Say Hello"
                accentButton: true
                onClicked: {
                    var msg = helloDemo.formatGreeting(helloDemo.transposeSteps)
                    console.log(msg)
                }
            }
        }
    }
}