# OTA Software Update Solution with DFU and P2P Scenario Design for End Users

## Introduction

This project focuses on building an OTA update system that prioritizes handling single-point errors in updates between end users and servers through DFU and P2P scenario design between end users and servers, ensuring smooth, seamless operation and guaranteeing software availability to users.

---

## Structure

- `Code/`: Entire project source code.
  - `arduino/`: Source code compatible with ArduinoIDE.
  - `idf/`: Source code compatible with ESP-IDF.
  - `script/`: Linux bash scripts for handling logic at the server and gateway.
- `Documentation/`: Documentation and design notes.
  - `esp32/`: Documents related to ESP32.
  - `misc/`: Other miscellaneous documents for the project.
  - `paper/`: Research papers for reference purposes.
  - `report/`: Report files.

---

## Features

- **Implementing** a wireless firmware update protocol with FTP allows for device upgrades without disassembling the hardware.
- **Design** process that allows a successfully updated device to act as a "source" for transmitting firmware to other devices in the vicinity.

---

## Hardware Components

- **ESP32-WROOM-32** acts as the end-user device in 2 scenarios.
- **ESP32-S3** acts as the end-user device source with pre-installed firmware.
- **NVIDIA Jetson Nano** acts as an intermediary gateway device within the entire system.
- **Laptop running Linux Fedora** acts as the main server and local network source for the system to operate.
