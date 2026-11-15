# Replacement components

The Mac build does not run the original Windows program directly. SwARc statically
recompiles the game program for Apple silicon, and the platform services around it are
a mixture of runtime code and replacements written for this port.

This is a summary of the larger differences. It is not a promise that every legacy
Windows behaviour is reproduced exactly.

| Area | Replacement or difference |
| --- | --- |
| Graphics | DirectDraw 7 and Direct3D 7 are implemented over SDL and Metal. Some GDI calls are accepted without drawing. |
| Sound | The QMixer interface is replaced and runs over the runtime mixer. Voice timing follows the host clock, so it is not sample-identical to the original. |
| Movies | Bink movies are played with an FFmpeg-based replacement. Some playback statistics reported to the game are simplified. |
| Clock and timers | Timing calls read the host’s steady clock. Sleep and thread timing therefore follow the Mac rather than a Windows machine. |
| Files | Game paths are matched case-insensitively on the Mac file system. The imported install is treated as read-only, with writable data kept separately. |
| Registry | Windows registry data is held by the runtime and saved in its own text format. |
| Input | DirectInput is mapped to the runtime implementation. Mac trackpad gestures and Control/Option-click are translated into the mouse input the game expects. |
| Legacy services | Some old Windows, networking, joystick, MIDI, and setup services have no Mac equivalent here and return fixed or no-device answers. |
| Frame rate | Interactive runs are normally capped at 60 frames per second. The cap changes presentation rate, not the game’s turn rate. |
| Closing | Window close, Cmd-Q, and Dock Quit are passed to the game as a normal close request. If the game is in a sequence that ignores close requests, the app waits before ending the process. |

The replacement display, sound, movie, and timing code can behave differently from
the original Windows components even when the game simulation itself agrees.
