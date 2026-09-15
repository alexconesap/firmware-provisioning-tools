# Firmware Flashing Kit

This folder contains simple tools to install (or reinstall) firmware onto a
device's control board, using nothing more than a USB cable and the
Arduino IDE you probably already have installed.

## Why does this exist?

Normally, our machines update their own firmware automatically over the
network (this is called "OTA" — Over-The-Air). You don't need to do
anything for that.

But a **brand-new control board**, fresh out of the box, doesn't have any
firmware on it yet — so it can't update itself. Someone has to load the
first firmware onto it by hand, over a USB cable. That's what this kit is
for.

It's also useful if a board ever gets into a bad state and needs to be
wiped and reloaded from scratch.

## What you need before you start

- A Windows/Mac or Linux computer with **Arduino IDE** installed (that's it — you do
  **not** need to install anything else).
- A USB cable connecting the board to your computer.
- To know two things about the board you're flashing:
  1. **Which product it belongs to** (for example `wendy`, `sol`, `nicky`, `fs-uv`, `benny`, ...)
  2. **Which specific board/module it is**, if the product has more than one
     (for example `wendy` has three: `main`, `rbtensy`, `rbwendy` — usually
     there's a label on the board, or ask whoever gave you the task)

## How to use it

### Microsoft Windows

#### 1. Install firmware onto a board

Double-click `flash.bat` in this folder, or open a Command Prompt here and
run:

```shell
flash.bat <product> <module>
```

(On a Mac or Linux dev machine, use `./flash.sh <product> <module>` instead
— same behavior.)

For example, to flash the "rbtensy" board that's part of the "wendy"
machine:

```shell
flash.bat wendy rbtensy
```

> **Why `.bat` and not `.ps1` directly?** Windows normally refuses to run
> `.ps1` scripts that aren't digitally signed ("...cannot be loaded because
> running scripts is disabled on this system" / "...is not digitally
> signed"). `flash.bat` sidesteps that for you. If you (or a script) call
> `lib\flash.ps1` directly instead, you'll need:
> `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "lib\flash.ps1" <product> <module>`
> — note the script path and the `<product> <module>` arguments are
> separate, not one combined quoted string.

The tool will:

1. Ask what you want to do:
   - **1) Update firmware** (just press Enter) — the board already runs this
     product's firmware and you only want to reload or update it.
   - **2) Full flash** — the board is brand-new, came with some other
     firmware on it (for example a manufacturer demo), or keeps restarting
     after a normal update. This needs firmware files prepared for you by
     the team in advance.
2. Figure out which USB port the board is on.
3. Download the correct, latest official firmware for that exact board (or
   use the prepared files, for a Full flash).
4. Write it onto the board.
5. Tell you clearly whether it worked or not.

If you choose **1) Update firmware** but the board actually needs a Full
flash (it's blank, or has some other firmware on it), the tool notices
before writing anything, stops, and tells you to run it again and choose
**2) Full flash**.

(From the command line, `flash.bat <product> <module> -Full` skips the
question and goes straight to a Full flash.)

If something goes wrong, it will print a plain-English message explaining
what to check (USB cable, board not detected, no internet connection, etc.)
rather than a cryptic error.

You do **not** need to know what chip is inside the board, what a
"partition table" is, or how to use any developer tools — the script
figures all of that out by itself, including finding the tools bundled
inside your Arduino IDE installation.

#### 2. Fully wipe a board

If a board is stuck, misbehaving, or you're told to "reset it completely,"
use the same `<product> <module>` you'd give `flash`:

```shell
reset.bat <product> <module>
```

It asks what to erase:

- **1) Settings only** (just press Enter) — erases the board's saved
  settings and pairing so it starts fresh the next time it's powered on.
  The firmware stays.
- **2) Everything** — also removes the firmware. Only do this if whoever
  assigned the task asked for a full wipe: the board won't work again until
  you run `flash.bat` and choose **2) Full flash**.

> This is specially useful when you want to reuse an existing board that was
already paired to another device; the pairing details are stored on the board
so to reuse the board it is required to wipe out the pairing data first.
>
> **Pairing is remembered on both sides.** The "main" board remembers every
> node it's paired with, and each node remembers its "main" board, each on
> its own. Resetting only one of the two leaves the pairing looking intact
> from the other one's side — to fully un-pair a board, run `reset.bat` on
> **both** the node and the "main" board it was paired to.

## Something isn't working right after a flash

Two more tools help figure out what's happening on the board itself:

- **`monitor.bat <product> <module>`** — shows you everything the board is
  printing (boot messages, errors, crash logs) in real time. Leave it
  running and watch. Press Ctrl+C (or just close the window) to stop.
- **`reboot.bat <product> <module>`** — restarts the board without
  re-flashing anything. Handy to force a fresh boot while `monitor.bat` is
  open in another window, to see exactly what happens from power-on.

If a board seems completely silent in `monitor.bat` even right after
`reboot.bat`, or keeps restarting over and over, tell whoever assigned the
task — it likely needs `flash.bat` with **2) Full flash** rather than the
normal update.

## What if I have no internet connection on-site?

The tool can also work from firmware files already saved on your computer,
if someone has prepared them for you in advance — it will use those instead
of downloading anything.

## Something went wrong / I'm not sure what to do

Stop and ask the team rather than guessing — reflashing the wrong firmware
onto a board, or wiping the wrong one, can take a machine out of service.
The scripts are designed to double-check with you before doing anything
that can't be undone, but when in doubt, ask first.
