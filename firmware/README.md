# Paceman accessories

Paceman’s iPhone app connects to compatible hardware over Bluetooth. The phone
handles source networking and push delivery; firmware implements the
[accessory protocol](../docs/protocol.md#iphone-and-esp32-watch-ble) and displays activity.

Reference implementations:

- [Pebble Time 2](pebble-time-2/README.md): custom PebbleOS firmware, with the native
  launcher, Timeline, alarms and watchfaces retained.
- [ESP32 watch](esp32-watch/README.md): the original Waveshare AMOLED prototype.

Install compatible firmware first. In Paceman, open **Settings → Experimental →
Accessories → Connect accessory**, choose your hardware, and follow its setup
instructions. Multiple accessories can stay paired and receive the same activity.
Updates and removal are independent for each device.

Other hardware implements the service and authenticated owner pairing, and
advertises only supported capabilities. Preserve published packet versions when
adding features.
