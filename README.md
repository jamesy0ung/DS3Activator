# DS3Activator for macOS

A lightweight menu bar utility to automatically activate Sony DualShock 3 (PS3) controllers connected via USB on modern macOS.

**Tested successfully on macOS Sequoia with an M4 MacBook Pro.**

## The Problem

On **macOS Monterey (12.0) and later**, the operating system recognizes a DualShock 3 controller plugged in via USB, but fails to send the specific activation command required for it to function correctly. This results in the controller being detected but not usable.

## The Solution

**DS3Activator runs in the background and solves this problem.** It monitors USB connections:

1.  **Detects** a connected DualShock 3 (by its Vendor ID `0x054C` and Product ID `0x0268`).
2.  **Automatically sends** the necessary HID activation command.
3.  **Notifies** you when the controller is connected and activated.

Your controller should then work as expected.

## Features

*   **Automatic Activation:** Fixes DS3 USB connectivity on Monterey+.
*   **Menu Bar App:** Runs discreetly with quick access to settings.
*   **Notifications:** Informs you of connection and activation status (configurable).
*   **Launch at Login:** Option to start automatically with your Mac (configurable).
*   **Modern & Lightweight:** Uses standard macOS frameworks. Recieves callbacks from IOKit to avoid polling, resulting in 0% CPU usage when not activating a controller.

## Usage

1.  Launch **DS3Activator**. Its controller icon will appear in your menu bar.
2.  Plug in your **DualShock 3 controller via USB**.
3.  You'll receive a notification confirming detection and activation.
4.  Your controller is ready to use!

## Requirements

*   **macOS Monterey (12.0) or later**
*   Sony DualShock 3 Controller
*   USB Cable
