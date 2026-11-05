# Orbit Linux Companion

A native Qt tray companion for Wayland and X11, using Orbit's existing authenticated
HTTPS API, SRP PIN pairing, and persistent certificate identity. Hyprland is the
primary target; KDE Plasma, GNOME and other desktops use the same standard tray,
ScreenCast portal and PipeWire interfaces where available.

**This is a Linux port in progress, not full Windows feature parity.** The core API,
tray, remote preview/input, webcam and Hyprland virtual displays are implemented.
Hyprland 0.57 virtual output creation, mode changes, capture and restoration have
been exercised with disposable headless outputs. Full phone interoperability and
the other desktops still need validation. The compatibility list below identifies
the remaining work. Helper availability does not imply compositor permission.

## Install

Keep the complete repository checkout: the Linux entry point reuses the modules in
`Orbit-Windows-Agent` for pairing, TLS, monitoring, files, history and automation.
Python 3.11+ is required. Run as your desktop user, **without sudo**.

```sh
python3 Orbit-Linux-Agent/install.py
~/.local/bin/orbit-companion
```

The installer creates `.venv-linux`, an application-menu entry, and a user-local
launcher pointing at this checkout. Keep the checkout in place. Re-run the installer
after updating the checkout. It does not alter system services, load kernel modules,
open firewall ports, or enable startup automatically. Use **Start at login** in the
tray to write an XDG autostart entry. For compositors that do not process XDG autostart,
start the launcher in the compositor config (Hyprland's legacy syntax:
`exec-once = orbit-companion`; use the equivalent startup action with Lua config).
Use one startup mechanism, not both.

Install desktop helpers through your distribution:

- `pactl` (PulseAudio utilities, also works with PipeWire's PulseAudio server),
  `playerctl`, `xdg-open`, `gio`, `loginctl` and `systemctl`.
- Wayland: `wl-clipboard`, `wtype` on virtual-keyboard-capable compositors such as
  Hyprland/Sway, and `grim` for native monitor preview/direct touch. Native pointer
  input uses PyWayland and the compositor's wlr virtual-pointer protocol.
  `ydotool` with a configured `ydotoold` is the fallback on other compositors.
- X11: `xdotool` and `xclip`.
- Screen preview: Qt Multimedia's FFmpeg backend, PipeWire and
  `xdg-desktop-portal` with the backend for your compositor, for example
  `xdg-desktop-portal-hyprland`, `xdg-desktop-portal-kde` or `xdg-desktop-portal-gnome`.
  Qt's Wayland screen capture is documented as experimental upstream.
- Full streaming: [Sunshine](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2getting__started.html),
  installed/configured separately. Orbit retains its Sunshine discovery, credentials,
  pairing PIN, app library and streaming integration.

### NixOS

Use the native Nix package instead of installing binary Qt wheels into a venv:

```sh
nix-build Orbit-Linux-Agent/default.nix
./result/bin/orbit-companion --doctor
./result/bin/orbit-companion
```

To install declaratively, add `(pkgs.callPackage /absolute/path/to/Orbit/Orbit-Linux-Agent {})`
to `environment.systemPackages` or your Home Manager packages. The wrapper preserves
Qt plugins and helper paths when launched from the application menu or at login.

For Hyprland, configure the compositor's portal and PipeWire normally, and enable a
StatusNotifier tray (for example Waybar's `tray` module). GNOME needs a compatible
tray extension; without a tray Orbit keeps a connection-details window available.

Hyprland/Sway native pointer input does not need `ydotoold`, `/dev/uinput` access,
or an input group. On compositors without the virtual-pointer protocol,
`ydotoold` uses `/dev/uinput`. Configure the distribution's daemon with a socket that
only your desktop user can access and set `YDOTOOL_SOCKET` in the session environment
if necessary. On NixOS, `programs.ydotool.enable` and membership in its configured
socket-access group can provide this. Orbit itself does not run as root or invoke
sudo. The daemon grants desktop input capability to clients with access to its socket.

## Pair and run

1. Start Orbit inside the graphical login session, preserving `WAYLAND_DISPLAY`
   or `DISPLAY` and the session D-Bus environment.
2. Permit TCP **8766** and mDNS UDP **5353** on the trusted LAN as needed.
   This Linux launcher serves HTTPS only; it does not open the legacy HTTP port.
3. On the phone, choose **Find my PC**, select the Linux PC, and enter the six-digit
   code displayed in the Qt dialog. Codes expire after two minutes and disappear
   when consumed. They are never written to the log or desktop notifications.
4. Use **Connection details** for the address, port and certificate fingerprint.
   **Copy manual pairing token** is an explicit local action for manual setup.
5. For screen preview, approve the portal's screen chooser on the PC. **Stop screen
   sharing** in the tray immediately clears the preview and closes the capture.
   Only one preview session is accepted at a time.

Run `orbit-companion --doctor` or use **Desktop capabilities** to inspect session
and helper availability. `ORBIT_HOST` and `ORBIT_TLS_PORT` configure the listener.
Secrets, TLS identity, settings, session history and a rotating `agent.log` are stored
in `$XDG_DATA_HOME/Orbit` (default `~/.local/share/Orbit`), in a user-owned private
directory. Removing the TLS identity requires pairing again.

### Remote input

On Hyprland/Sway, Unicode text and shortcuts use `wtype`; pointer movement, clicks,
drag and scroll use a persistent native Wayland virtual pointer. Orbit detects the
protocol when input first arrives and falls back to `ydotool` if it is unavailable.
A failed operation is never replayed through another backend. GNOME/KDE default to `ydotool` for keys too because the
virtual-keyboard protocol is not universal. Set `ORBIT_KEYBOARD_BACKEND=wtype` or
`ydotool` to override keyboard selection on another compositor. `ydotool` text typing
uses the system's key mapping; use Clipboard for non-ASCII text when `wtype` is not
supported. Set `ORBIT_POINTER_BACKEND=wayland` to require native input or `ydotool`
to force the fallback; the default is `auto`. X11 uses `xdotool` for keyboard and pointer input.

For **direct touch on Hyprland/Sway**, choose a monitor under **Screen preview
source** in the tray, start preview on the phone, then approve the local screen
sharing dialog. `grim` captures that named output and the virtual pointer binds to
the same `wl_output`, including its scale, rotation and position. No desktop-wide
coordinate guessing is used. Output binding needs virtual-pointer v2 and wl_output
v4. Disconnecting the monitor stops capture and refuses subsequent direct-touch input.
The monitor choice is session-only; each stream requires local approval.

**Portal chooser** remains the default and supports relative trackpad input across
desktops. Qt does not expose the portal's selected output identity, so direct touch
is refused in this mode. Native capture/input availability depends on compositor
protocol support. Use Sunshine for full-desktop streaming at higher frame rates.
X11 direct touch maps to the primary screen captured by Qt. Held drag buttons are
released when the input connection closes, sharing stops or Orbit exits.

### Use the phone as a Linux webcam

Orbit receives the same authenticated JPEG camera stream as the Windows companion
and sends it to a designated `v4l2loopback` device through `pyvirtualcam`. This works
independently of Wayland/X11. It never selects a physical webcam or automatically
takes over another application's loopback camera.

Install your distribution's v4l2loopback kernel module, then configure a device
named **Orbit Camera**. For example, on Debian/Ubuntu with matching kernel headers:

```sh
sudo apt install v4l2loopback-dkms
sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="Orbit Camera" exclusive_caps=1
```

Choose an unused video number and ensure your desktop user has read/write access
to the resulting `/dev/video10` through the distribution's ACL or `video` group.
If the module is already in use, follow its device-management instructions instead
of unloading cameras used by other apps. For an existing loopback device with a
different name, set `ORBIT_WEBCAM_DEVICE=/dev/videoN` in Orbit's environment.

On NixOS, the equivalent module configuration is:

```nix
boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
boot.kernelModules = [ "v4l2loopback" ];
boot.extraModprobeConfig = ''
  options v4l2loopback devices=1 video_nr=10 card_label="Orbit Camera" exclusive_caps=1
'';
```

Start **Webcam** on the phone, then select **Orbit Camera** in OBS, your browser or
your conferencing app. With `exclusive_caps=1`, it appears as a capture device only
after Orbit starts sending. Sandboxed apps may need camera permission. Only video
is transmitted; keep using the PC microphone. Linux does not reliably report which
app opened the virtual camera, so the phone displays streaming status instead.
Stop the stream before changing its resolution in an app already using the camera.

Kernel setup/removal stays in the local package manager. The phone does not offer
the Windows driver installer on Linux. See
[v4l2loopback setup](https://github.com/v4l2loopback/v4l2loopback) and
[pyvirtualcam](https://github.com/letmaik/pyvirtualcam) for distro-specific details.

### Hyprland Fill Screen and Second Screen

Start Orbit and Sunshine inside the same graphical login session. Keep the
session's matching `hyprctl` on Orbit's PATH. In the phone app, save the Sunshine
login and use **Fill Screen → Set Up This PC**, or start **Second Screen**.
No virtual-display kernel driver or administrator prompt is needed.

Orbit creates a randomly named `ORBIT-…` headless output, sets its resolution and
refresh rate, and places it to the left or right of the desktop. Placement accounts
for existing monitor scale, rotation and negative coordinates. It uses the legacy
Hyprland monitor API or the active Lua API on newer releases. Runtime changes do
not edit your compositor config. A compositor config reload can reset the output;
Orbit reports the actual mode and reapplies the requested mode at stream startup.

Sunshine uses `capture=wlr` and the output's stable name. Orbit preserves the previous
capture settings and appends its own startup/exit commands to `global_prep_cmd`,
retaining existing commands. The startup hook sizes the output to the client's
requested resolution/FPS before Sunshine starts capture. Fill Screen focuses the
virtual output so new apps open there; existing windows can be moved onto it.
Second Screen leaves the physical screens available and never puts them to sleep.

**Turn off the PC's monitor** uses DPMS while the Sunshine app runs. It records each
monitor before putting it to sleep and wakes only those monitors afterward. Sunshine
runs the exit hook when its app quits, so disconnecting while leaving the app running
does not immediately restore the screens. **Restore displays and Sunshine settings**
in the Orbit tray wakes them even during an active session; quit the Sunshine app
before restoring its capture configuration. Orbit also wakes monitors when it exits.

A private `linux-display.json` journal and cross-process lock cover the companion
and Sunshine hooks. Interrupted changes can be restored from the tray or recovered
when Orbit next starts while Sunshine is idle. Restoration removes only Orbit's
recorded output in the same compositor session and only settings still equal to the
values Orbit applied. User edits and unrelated preparation commands are retained.
Do not delete the journal before restoring displays. Keep the launcher/check-out
available while these hooks are configured.

**Virtual-display streaming is SDR.** Sunshine's wlr capture path does not supply
HDR video. The phone shows this limitation, and the startup hook rejects an HDR
request before changing monitor power. Disable HDR in Stream Settings. Orbit does
not change the HDR/color settings of your physical monitors. Other compositors
retain remote preview/input and Sunshine streaming but do not advertise automatic
virtual display management.

## Compatibility and remaining parity work

Implemented through the shared agent plus Linux adapters:

- Bonjour, SRP PIN pairing, pinned TLS, control/widget token separation.
- CPU/RAM/disk/network monitoring, Linux hwmon temperatures/fans/clocks, NVIDIA SMI
  where available; unreadable sensor values remain unavailable.
- File browsing, transfer, archives, rename/move and desktop Trash via Send2Trash.
  Trash errors never fall back to permanent deletion. Credential, symlink and hard-link
  protections remain in place; Linux names are not subjected to Windows device-name rules.
- Process listing/termination with creation-time checks and protection for other users,
  the companion, its ancestors and desktop/compositor processes.
- Clipboard text, PulseAudio/PipeWire master and per-stream volume/mute/output routing.
  Output routing affects the live stream rather than a persistent Windows application policy.
- Power/lock through systemd/logind's existing policies, MPRIS media keys, desktop shortcuts.
  Shortcut meaning depends on compositor bindings; lock requires a configured session locker.
- XDG application catalog, custom button decks, keyboard/text/URL actions and OBS buttons.
- Presentation keyboard control (LibreOffice, browser presentations, focused presenter).
- Shared session history, events, alerts, watched processes, power-after rules, energy
  estimates, summaries and push relay integration.
- Native/Flatpak Steam library/download discovery and the existing Sunshine API.
- Consent-mediated Qt screen preview on Wayland; native Qt capture on X11.
- Native Wayland pointer input and consent-mediated named-monitor direct touch on
  Hyprland/Sway-compatible compositors, with bounded JPEG preview.
- Phone webcam through a locally configured v4l2loopback camera, with Linux-aware
  setup and streaming messages in the phone UI.
- Hyprland virtual Second Screen, phone-sized Fill Screen, startup mode changes,
  optional physical-monitor sleep and journaled restoration of displays/Sunshine.

Remaining work before claiming full parity:

- Automatic Linux webcam kernel-module setup/removal. Streaming itself is implemented;
  Windows Softcam binaries are never downloaded or installed by the Linux app.
- Virtual second screens and display management outside Hyprland; HDR streaming and
  physical-monitor HDR controls. `streamDisplay` and `secondScreen` are advertised
  only in a Hyprland session with `hyprctl` available.
- PowerPoint COM slide notes/thumbnails/metadata (Linux currently provides keys only).
- Linux foreground-game identification, per-process GPU counters and FPS sources such
  as MangoHud; Windows WDDM/RTSS/Afterburner cannot supply these on Linux.
- Epic/GOG native Linux launcher adapters, pre-login service/handover, and a Linux-specific
  updater. The Windows source-archive updater is rejected; update using the installer
  or package manager.
- Direct touch through the portal-selected screen on GNOME/KDE; use the native
  monitor path on compatible compositors or Sunshine.

## Validation

```sh
python3 -m pip install -r Orbit-Linux-Agent/requirements.txt httpx
python3 -m unittest discover -s Orbit-Linux-Agent/tests -p test_linux.py -v
python3 -m unittest discover -s Orbit-Linux-Agent/tests -p test_display.py -v
python3 -m unittest discover -s Orbit-Linux-Agent/tests -p test_native.py -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s Orbit-Linux-Agent/tests -p test_tray.py -v
python3 -m unittest discover -s Orbit-Windows-Agent -p 'test_*.py'
# With swiftc installed: Linux service JSON against the production Swift model.
python3 Orbit-Linux-Agent/tests/check_swift_display.py
# Optional live compositor check: creates/captures/removes disposable headless outputs.
python3 Orbit-Linux-Agent/tests/integration_hyprland.py --run
```

On NixOS, the packaged Python with native Qt is available via
`nix-build Orbit-Linux-Agent/default.nix -A python`; use its `bin/python` for the
headless tray tests. For the Swift contract check, use
`nix-shell -p swift --run 'python3 Orbit-Linux-Agent/tests/check_swift_display.py'`.
Unit tests never inject input, change volume/power, or capture the real desktop.
The opt-in Hyprland integration test changes only its disposable outputs, uses a
fake Sunshine service, and verifies existing monitor geometry/power/color settings
are unchanged. It passed on Hyprland 0.57; legacy and transitional APIs have mocked
contract coverage. Manual validation should cover pairing from iOS, portal approval and
denial, native monitor approval/denial, mixed-scale/rotated monitor direct touch,
monitor hot-unplug, relative input and drag release, Unicode clipboard, tray restart,
webcam frames in a real consumer, and shutdown while a phone is connected on Hyprland,
Plasma Wayland, GNOME Wayland and X11. Also verify actual Sunshine startup/exit hooks,
phone-sized streams, display recovery after a forced exit and the opt-in DPMS option.
The Swift display model can be tested on Linux; full iOS UI, pinned networking,
webcam tests and app builds still need the Apple SDKs.

References: [Qt tray support](https://doc.qt.io/qt-6/qsystemtrayicon.html),
[Qt ScreenCapture](https://doc.qt.io/qt-6/qscreencapture.html),
[wlr virtual pointer](https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/master/unstable/wlr-virtual-pointer-unstable-v1.xml),
[ydotool](https://github.com/ReimuNotMoe/ydotool), [wtype](https://github.com/atx/wtype).
Display references: [Hyprland outputs](https://wiki.hypr.land/Configuring/Advanced-and-Cool/Using-hyprctl/),
[Hyprland monitor rules](https://wiki.hypr.land/configuring/core/monitors/),
[Hyprland dispatchers](https://wiki.hypr.land/configuring/core/dispatchers/),
[Sunshine capture configuration](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html).
