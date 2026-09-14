from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication, QLabel, QMainWindow

app = QApplication([])

window = QMainWindow()

label = QLabel("Holy crap, PySide on a Pixel.")
label.setAlignment(Qt.AlignmentFlag.AlignCenter)
window.setCentralWidget(label)

# Don't depend on an X11 window manager.
window.setWindowFlag(Qt.WindowType.FramelessWindowHint)


#
# Termux:X11 reports a placeholder resolution (1280x1025) until its
# Android activity attaches, then resizes the X screen via RANDR. Without
# a window manager nothing resizes us in response, so track the screen
# ourselves and re-apply its geometry every time it changes.
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
