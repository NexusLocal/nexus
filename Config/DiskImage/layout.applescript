-- Sets the Finder window of the mounted, writable disk image "Nexus".
-- The result is the file .DS_Store on the disk image. Keep a copy of it as Config/DiskImage/DS_Store.

tell application "Finder"
	tell disk "Nexus"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 200, 840, 572}
		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set shows item info of viewOptions to false
		set shows icon preview of viewOptions to false
		set icon size of viewOptions to 128
		set text size of viewOptions to 13
		set background picture of viewOptions to file ".background:background.tiff"
		set position of item "Nexus.app" of container window to {170, 192}
		set position of item "Applications" of container window to {470, 192}
		set position of item ".background" of container window to {320, 800}
		update without registering applications
		delay 2
		close
		open
		delay 2
		close
	end tell
end tell
