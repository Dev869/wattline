# ANT+ without an ANT+ stick

The short version: **a Mac cannot receive ANT+ on its own hardware, and no
amount of software changes that.** What it can do is let something else be the
aerial. That is what this branch builds.

The useful split turns out to be that getting the bytes off the air needs a
radio, and everything after that is arithmetic. The arithmetic is here,
finished and tested. The radio is a decision about what you already own.

## Why the Mac cannot do it

ANT is a Nordic/Garmin protocol. Over the air it is Enhanced ShockBurst: GFSK
at 1 Mbps with 160 kHz deviation, a one-byte preamble, a five-byte address, the
payload, and a two-byte CRC. Every ANT+ device profile sits on one frequency,
2457 MHz. That is close enough to Bluetooth LE to sound promising — same band,
same modulation family — and it does not matter, because a Bluetooth
controller will not hand you the raw PHY. It demodulates BLE link-layer packets
and gives you those. There is no mode where it returns arbitrary ShockBurst
frames.

On this machine specifically:

    Chipset:  Apple N1
    Transport: PCIe
    Supported services: HFP AVRCP A2DP HID Braille LEA AACP GATT SerialPort

Apple's own wireless silicon, closed firmware, no vendor HCI surface exposed to
userspace, and macOS has no raw HCI channel to send one down even if it did.
The N1 speaks Bluetooth, Wi-Fi and Thread. Thread is 802.15.4, which is a
different PHY again — being on the same band buys nothing.

Two more dead ends, checked so they stay checked:

- **nRF24L01+ as a bare receiver.** Tempting, because ANT's over-the-air format
  *is* ShockBurst and the nRF24 family is the radio ANT chips are built on. But
  the protocol stack — channel timing, the search and pairing behaviour, the
  network key that becomes the address — is only sold in silicon, and Garmin
  does not license a software implementation. People have sniffed ANT with an
  nRF24 and with SDRs; nobody has a maintained receiver you would trust with a
  workout.
- **SDR.** Genuinely possible and genuinely demonstrated — the DEF CON 24
  `antfs-poc` work decodes ShockBurst and ANT-FS from IQ captured off a Pluto.
  It is a research toolchain, not a sensor driver, and it needs an SDR that
  covers 2.4 GHz with a megahertz of bandwidth. That is more hardware and more
  fragility than a $25 dongle on a Raspberry Pi.

Nothing on this machine could have done it anyway. No USB peripherals attached,
no serial radios, no `rtl_sdr`, `hackrf_info`, `SoapySDRUtil`, `nrfutil` or
`openant` installed.

## What actually works

**Check first whether you need ANT+ at all.** Most sensors made since roughly
2016 broadcast ANT+ and BLE at the same time — a KICKR, a Vector, a modern HRM
all do. Wattline already reads those, and the Sensors group in Settings lists
whatever is advertising. If your kit shows up there, stop reading.

If it is genuinely ANT+-only — an older power meter, a first-generation
speed/cadence sensor, a strap that predates dual broadcast — the options are:

1. **Relay from a machine that has a radio.** Put a dongle in a Raspberry Pi,
   an old laptop, anything that is not a Mac, and forward the packets. This is
   what `relay/wattline-relay.py` does, and what the rest of this branch
   receives. It is the cheapest and least fragile answer.
2. **A hardware bridge.** The NPE CABLE takes ANT+ in and advertises BLE out,
   so the Mac sees an ordinary BLE sensor and nothing in Wattline has to know.
   Worth knowing that a bridge will not carry trainer control — you get the
   numbers, not ERG.
3. **A device you already own doing the same job.** Many Garmin watches and
   head units will re-broadcast heart rate over BLE. That covers HR only, and
   costs nothing.

## What is in this branch

`ant.py` decodes ANT+ broadcast pages into the same `BikeState` the Bluetooth
side fills: heart rate, bike power, speed and cadence in all three sensor
combinations, and fitness-equipment pages from a trainer. Eight bytes in, a
sensor reading out. No radio and no licence involved, so it is testable on a
machine with neither, and `test_ant.py` builds each page the way a sensor would
and checks it decodes back — including the twelve-bit power field a trainer
splits across two bytes, and the difference between "no reading" and "zero".

`ant_relay.py` listens for those pages as UDP datagrams. The wire format is
nine bytes, a device type and the sensor's eight, so a relay for some other
aerial is an evening's work rather than a project. Localhost only unless you
pass `--ant-relay-lan`, and anything that is not exactly nine well-formed bytes
is dropped without comment after the first.

`relay/wattline-relay.py` is the other end, meant to run on the machine with
the radio. Its `--fake` mode sends a simulated rider and is what proved the
path end to end; the real openant path is written against openant's own
examples and is **untested against a dongle**, because there is not one here.

## If you want to try harder

The parts that would make this stick-free in the strict sense, in rough order
of how likely they are to work:

- **An nRF52840 dongle with the S340 SoftDevice.** This is Nordic silicon with
  a real, licensed ANT stack — a combined BLE and ANT protocol stack Garmin
  distributes for the 52840. Flash it, and a $10 generic dongle does what a $45
  ANT stick does, over USB CDC. It is still a USB radio, so whether that counts
  as "no stick" depends on what you meant, but it is not an ANT+ stick and it
  is not single-purpose. The licence terms are the obstacle worth reading
  before the code is.
- **Anything of yours that already has an ANT radio.** Some Android phones ship
  one. An old Edge or Forerunner has one. Either could be the aerial for the
  relay above with a small app on top.
- **SDR, if you have one already.** The `antfs-poc` blocks are a starting
  point, and `ant.py` is waiting for whatever they produce. Do not buy hardware
  for this.

What would not be worth trying again: anything that hopes the Mac's own radio
can be talked into it.

## Sources

- [rtl_433 #1990, decoding ANT and ANT+ packets](https://github.com/merbanan/rtl_433/issues/1990)
- [sghctoma/antfs-poc-defcon24](https://github.com/sghctoma/antfs-poc-defcon24)
- [Nordic S340 ANT SoftDevice](https://www.nordicsemi.com/Products/Development-software/S340-ANT)
- [Using ANT+ on an nRF52840 Dongle](https://devzone.nordicsemi.com/f/nordic-q-a/109392/using-ant-on-my-nrf52840-dongle)
- [nRF24L01+ and ANT+, Nordic DevZone](https://devzone.nordicsemi.com/f/nordic-q-a/885/nrf24l01-and-ant)
- [The CABLE by NPE: ANT+ to Bluetooth bridge](https://support.wahoofitness.com/hc/en-us/articles/4402696141586-The-CABLE-by-NPE-ANT-to-Bluetooth-Bridge)
- [Garmin wearable heart rate broadcasting, DC Rainmaker](https://www.dcrainmaker.com/2020/04/garmin-wearable-broadcasting.html)
