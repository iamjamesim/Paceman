Paceman Watch @VERSION@
======================

Supported hardware:
  Waveshare ESP32-S3-Touch-AMOLED-2.06

Requirements:
  - a USB data cable connected to the board's programming port
  - Espressif esptool 4.x or 5.x

Flash:
  ./flash.sh /dev/ttyACM0

Replace /dev/ttyACM0 if the board appears at another serial port. The helper
writes the bootloader, partition table, and application at separate offsets.
It does not erase the NVS partition containing pairing and settings.

Files:
  bootloader.bin         offset 0x0
  partition-table.bin    offset 0x8000
  paceman_watch.bin      offset 0x10000

Verify the files before flashing:
  sha256sum -c SHA256SUMS
  On macOS: shasum -a 256 -c SHA256SUMS

Source and documentation:
  https://github.com/iamjamesim/paceman

Origin:
  https://github.com/iamjamesim/omarchy-watch

Licenses and provenance:
  LICENSE (Paceman), UPSTREAM_LICENSE (Omarchy Watch),
  THIRD_PARTY_NOTICES.md, UPSTREAM.md, and fonts-OFL.txt are included.
