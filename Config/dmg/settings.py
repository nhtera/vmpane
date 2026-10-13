# dmgbuild settings for the release disk image: VMPane beside an Applications link, on a background that says to
# drag one onto the other. scripts/make-dmg.sh passes the paths as -D defines.

app = defines["app"]  # noqa: F821 (dmgbuild provides defines)
here = defines["here"]  # noqa: F821

format = "ULFO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = app + "/Contents/Resources/AppIcon.icns"
background = here + "/background.tiff"

window_rect = ((200, 120), (540, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {"VMPane.app": (135, 175), "Applications": (405, 175)}
