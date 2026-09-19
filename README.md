# LambLisp - Real time *Lisp* for embedded control applications
### from [FrobeniusNorm.com](https://frobeniusnorm.com)

This is the **LambLisp** documentation stub.  Use these links to find more information about *LambLisp*.

### Start here

**[QUICKSTART.md](QUICKSTART.md)** -- what is in this package, how to run the binary, and how to
build and flash it.  It is a short read and it is the fastest way from this download to a `LL=>`
prompt.

- [LambLisp HTML manual at github](https://wawhite3.github.io/LambLispRT-v01-linux_x86_64/html/index.html)
- [LambLisp PDF manual at github](https://wawhite3.github.io/LambLispRT-v01-linux_x86_64/LambLisp.pdf)
- [Full LambLisp repositories on github](https://github.com/wawhite3/?tab=repositories&q=LambLispRT&type=&language=&sort=)

### Try it without installing anything

Run the published container image.  It boots straight to the `LL=>` prompt, installs nothing on
your machine, and is multi-architecture -- `docker pull` selects amd64 or arm64 for you:

    docker run --rm -it ghcr.io/lamblisp/lamblisp:runtime

Or open `demo/index.html` from this package to run *LambLisp* in your browser, with no download
and no toolchain.

### The other ways to get LambLisp

| | |
|---|---|
| **Linux** | this package, and the other `LambLispRT-v01-linux_*` repositories.  Requires glibc 2.34 or later (Debian 12, Ubuntu 22.04 LTS, RHEL 9 or newer) |
| **Windows** | a native `LambLisp.exe`, at [LambLispRT-v01-windows_x86_64](https://github.com/wawhite3/LambLispRT-v01-windows_x86_64) |
| **Container** | `ghcr.io/lamblisp/lamblisp:runtime` -- no host glibc or CPU requirement at all |
| **ESP32 and other boards** | the per-board `LambLispRT-v01-esp32*` repositories |

Building and flashing ESP32 firmware needs the Linux package and a local PlatformIO install; the
container carries the runtime only.

Shipped with this package:

- `QUICKSTART.md` - run it, build it, flash it: start here
- `BUILD-INFO` - exactly which commit, toolchain and feature set produced these binaries
- `LambLisp_ProductBrief.pdf` - product brief: specifications, embedded benchmarks and GC-pause figures
- `LambLisp_Announcement.pdf` - product announcement
- `LambLisp.pdf` / `html/` - the full reference manual
- `demo/` - the in-browser demo; open `demo/index.html`

Or visit the [Frobenius Norm website.](https://frobeniusnorm.com)

**LambLisp** is designed for intelligent automated control of physical processes.

*LambLisp* is a real-time implementation of the *Lisp* programming language, designed for compatibility with the *Scheme R5RS* and *R7RS* specifications,
with a large set of features to support real-time control and reuse of existing C/C++ device drivers.

LambLisp includes **Arduino**-style I/O and supports direct digital/analog pin access, I2C, WiFi, Bluetooth, and more.
The embedded control version of LambLisp is currently running on several variants of Espressif ESP32.
The LambLisp application for the Freenove 4WD autonomous vehicle provides examples of device driver interaction and other real-time capabilities.

LambLisp also runs on 64-bit Linux, both x86_64 and aarch64.
Although Linux does not offer real-time guarantees, the Linux versions of LambLisp have bindings available for Nvidia CUDA.
LambLisp can be linked with CUDA kernels and perform a supervisory role marshalling data to the AI coprocessor,
launching CUDA kernels, and reasoning about the results.

The combination of embedded LambLisp and LambLisp+CUDA offers tremendous potential.

Thank you for your interest in **LambLisp**.

Bill White
white3@FrobeniusNorm.com
