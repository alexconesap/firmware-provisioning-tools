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

Open PowerShell in this folder and run:

```shell
.\flash.ps1 <product> <module>
```

(On a Mac or Linux dev machine, use `./flash.sh <product> <module>` instead
— same behavior.)

For example, to flash the "rbtensy" board that's part of the "wendy"
machine:

```shell
.\flash.ps1 wendy rbtensy
```

The tool will:

1. Figure out which USB port the board is on.
2. Download the correct, latest official firmware for that exact board.
3. Write it onto the board.
4. Tell you clearly whether it worked or not.

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
.\reset.ps1 <product> <module>
```

This erases the board's saved settings so it starts fresh the next time
it's flashed or powered on. It does **not** remove the firmware itself —
for that, ask whoever assigned the task whether a full wipe
(`.\reset.ps1 <product> <module> -Full`) followed by a fresh `flash` is
needed instead.

> This is specially useful when you want to reuse an existing board that was
already paired to another device; the pairing details are stored on the board
so to reuse the board it is required to wipe out the pairing data first.

## What if I have no internet connection on-site?

The tool can also work from firmware files already saved on your computer,
if someone has prepared them for you in advance — it will use those instead
of downloading anything.

## Something went wrong / I'm not sure what to do

Stop and ask the team rather than guessing — reflashing the wrong firmware
onto a board, or wiping the wrong one, can take a machine out of service.
The scripts are designed to double-check with you before doing anything
that can't be undone, but when in doubt, ask first.
