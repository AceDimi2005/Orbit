# Wayland protocol bindings

`wlr-virtual-pointer-unstable-v1.xml` is from
[wlr-protocols](https://github.com/swaywm/wlr-protocols/blob/master/unstable/wlr-virtual-pointer-unstable-v1.xml).
Its MIT notice is retained in the XML and generated Python module.

`orbit_wayland_protocols/wlr_virtual_pointer_unstable_v1.py` was generated with
PyWayland 0.4.19. To regenerate, include the standard Wayland XML so the scanner can
resolve `wl_seat`, `wl_output` and pointer enum references:

```sh
python -m pywayland.scanner -i /usr/share/wayland/wayland.xml \
  Orbit-Linux-Agent/protocols/wlr-virtual-pointer-unstable-v1.xml -o /tmp/orbit-protocols
```

Copy only `wlr_virtual_pointer_unstable_v1.py` into `orbit_wayland_protocols` and
replace its `from .wayland import` statements with
`from pywayland.protocol.wayland import`. Standard protocol classes must come from
PyWayland's registry rather than a second generated copy. Nix provides the standard
XML through `pkgs.wayland`'s development output.
