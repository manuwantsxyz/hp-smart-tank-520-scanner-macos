# Why the HP Smart Tank 520 scanner fails on macOS

These are the symptoms with Image Capture, Preview, or scanning from System Settings:

- *"Waiting for scanner"* never finishes.
- *Failed to open a connection to the device (-21345)*.
- Scanning works sometimes and not other times, hangs halfway, or the scanner "disappears".

## How this printer scans

The Smart Tank 520 has no proprietary scanner protocol. It scans with **eSCL** (also known as AirScan or Mopria), which is **HTTP with XML**:

- `GET /eSCL/ScannerCapabilities`
- `POST /eSCL/ScanJobs`
- `GET …/NextDocument`

Over the network these requests travel over TCP. **Over USB** they use **IPP-over-USB**: the printer exposes USB interfaces of class 7/1/4, and the same HTTP traffic travels over their *bulk* endpoints.

## What macOS does

Apps don't talk to those interfaces directly. A system service, **`ippusbd`**, claims them, runs an HTTP proxy on `localhost`, and advertises it over Bonjour as a network scanner (`_uscan._tcp`). Image Capture uses that proxy through its AirScan module, as if the printer were on the network.

## The bug

USB gives you **a single channel**, so responses come back in the same order the requests went in. `ippusbd` shares that channel between the connections from different apps. But **when an app disconnects without reading its whole response, the proxy doesn't throw away what's left**. That happens, for example, when:

- a scan is cancelled;
- a window is closed;
- a timeout expires;
- the system sends a status query and abandons it.

The leftover data reaches the next connection as the answer to a different request. From then on, every response is **one behind**. Image Capture gets XML or image data that doesn't match what it asked for, so it hangs on "Waiting for scanner" or fails to open the connection with `-21345`.

Things recover only when the channel is reset:

- turning the printer off and on;
- unplugging the USB cable;
- `ippusbd` restarting.

That's why scanning **works sometimes and not others**.

## What about HP's driver?

HP's scanner module ("HP Scanner 3") doesn't list this model's USB ID (`03f0:4554`). macOS therefore leaves the printer to AirScan and `ippusbd`, and HP's software changes nothing.

## Can it be fixed?

**Not from the outside.** The bug is in a macOS component, so Apple has to fix it. HP can't fix it with a driver, because the printer behaves correctly.

What you can do is **avoid `ippusbd`**, which is what this app does:

1. It claims the IPP-over-USB interface directly with libusb, and only while it's scanning.
2. Before each request it **drains any leftover data** in the channel. The printer also sends zero-length packets, so it reads until the channel goes quiet.
3. It reads **one USB packet at a time** (512 bytes). On macOS, a large read that times out before a short packet arrives loses the partial data, which also desyncs the channel.
4. If you cancel mid-scan, it drains the channel and deletes the job on the printer (`DELETE` on the job URL). The scan head returns, and the next scan starts clean.
5. Before scanning it waits for the scanner to report `Idle`, because the head takes a few seconds to park.
6. It never resets the USB device: on this printer a reset makes interface 0 disappear. The app prefers the higher-numbered IPP-USB interfaces.

While the app is scanning, other apps that try to use the scanner get a "busy" error, and vice versa. That's why it's best to keep Image Capture closed.
