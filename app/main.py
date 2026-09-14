from PySide6.QtCore import Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtWidgets import QApplication, QLabel, QMainWindow

app = QApplication([])

# The same file runs in two very different places: packaged into an APK, and
# under Termux:X11 on the same tablet. They need opposite handling.
ON_ANDROID = QGuiApplication.platformName() == "android"

window = QMainWindow()

label = QLabel("Holy crap, PySide on a Pixel.")
label.setAlignment(Qt.AlignmentFlag.AlignCenter)
window.setCentralWidget(label)


#
# Termux:X11 reports a placeholder resolution (1280x1025) until its Android
# activity attaches, then resizes the X screen via RANDR. There is no window
# manager, so nothing resizes us in response: track the screen ourselves and
# re-apply its geometry every time it changes.
#
def fit_to_screen():
    geometry = window.screen().geometry()

    print(
        f"Fitting to screen geometry: "
        f"{geometry.width()}x{geometry.height()} "
        f"at {geometry.x()},{geometry.y()}",
        flush=True,
    )

    window.setGeometry(geometry)


def track(screen):
    screen.geometryChanged.connect(lambda _: fit_to_screen())


if ON_ANDROID:
    #
    # Qt maps QWindow::FullScreen onto Android's immersive mode, which is what
    # actually hides the status bar and the navigation bar / tablet taskbar.
    #
    # Packaging flags do not get you this: buildozer's `fullscreen = 1` only
    # drops the title bar (it stops passing `--window` to python-for-android),
    # and `orientation = landscape` only stops the app being letterboxed in a
    # portrait slab. The system bars are an application-level decision.
    #
    # Android hands Qt a correctly sized native window, so none of the screen
    # tracking below is needed here.
    #
    window.showFullScreen()
else:
    window.setWindowFlag(Qt.WindowType.FramelessWindowHint)

    for screen in app.screens():
        track(screen)

    app.screenAdded.connect(track)

    fit_to_screen()
    window.show()

    #
    # window.screen() is only meaningful once the native window exists, and
    # the window can be handed to a different QScreen later on.
    #
    window.windowHandle().screenChanged.connect(lambda _: fit_to_screen())

app.exec()
