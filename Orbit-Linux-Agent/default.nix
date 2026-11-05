{ pkgs ? import <nixpkgs> {} }:
let
  pyvirtualcam = import ./pyvirtualcam.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: with ps; [
    fastapi uvicorn websockets psutil mss pillow cryptography srptools zeroconf
    pyside6 send2trash pywayland
  ] ++ [ pyvirtualcam ]);
  helpers = with pkgs; [ pulseaudio playerctl wl-clipboard wtype ydotool grim xdotool xclip xdg-utils glib systemd ];
in pkgs.stdenvNoCC.mkDerivation {
  pname = "orbit-linux-companion";
  version = "4.5.2";
  src = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter = path: type:
      let relative = pkgs.lib.removePrefix (toString ../. + "/") (toString path);
          first = builtins.head (pkgs.lib.splitString "/" relative);
      in builtins.elem first [ "Orbit-Linux-Agent" "Orbit-Windows-Agent" "LICENSE" ]
        && builtins.baseNameOf path != "__pycache__"
        && !(pkgs.lib.hasSuffix ".pyc" path);
  };
  nativeBuildInputs = [ pkgs.makeWrapper pkgs.qt6.wrapQtAppsHook ];
  buildInputs = [ pkgs.qt6.qtbase pkgs.qt6.qtwayland pkgs.qt6.qtmultimedia ];
  passthru.python = python;
  dontWrapQtApps = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/orbit $out/bin $out/share/applications $out/share/icons/hicolor/scalable/apps
    cp -r Orbit-Linux-Agent Orbit-Windows-Agent LICENSE $out/lib/orbit/
    cp Orbit-Linux-Agent/orbit-linux.svg $out/share/icons/hicolor/scalable/apps/orbit-companion.svg
    makeWrapper ${python}/bin/python $out/bin/orbit-companion \
      "''${qtWrapperArgs[@]}" \
      --add-flags "$out/lib/orbit/Orbit-Linux-Agent/orbit_linux.py" \
      --prefix PATH : ${pkgs.lib.makeBinPath helpers} \
      --set ORBIT_LAUNCHER "$out/bin/orbit-companion"
    cat > $out/share/applications/orbit-companion.desktop <<DESKTOP
    [Desktop Entry]
    Type=Application
    Name=Orbit Linux Companion
    Exec=$out/bin/orbit-companion
    Icon=orbit-companion
    Terminal=false
    Categories=Network;Utility;
    DESKTOP
    runHook postInstall
  '';
  meta = {
    description = "Orbit phone companion and tray for Wayland and X11";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.linux;
    mainProgram = "orbit-companion";
  };
}
