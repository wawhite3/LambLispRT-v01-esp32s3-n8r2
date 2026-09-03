# LambLisp - Real time *Lisp* for embedded control applications
### from [FrobeniusNorm.com](https://frobeniusnorm.com)

This is the **LambLisp** documentation stub.  Use these links to find more information about *LambLisp*.

- [LambLisp HTML manual at github](https://wawhite3.github.io/LambLispRT-v01-linux_x86_64/html/index.html)
- [LambLisp PDF manual at github](https://wawhite3.github.io/LambLispRT-v01-linux_x86_64/LambLisp.pdf)
- [Full LambLisp repositories on github](https://github.com/wawhite3/?tab=repositories&q=LambLispRT&type=&language=&sort=)

Shipped with this package:

- `LambLisp_DataSheet.pdf` - product data sheet: specifications, embedded benchmarks and GC-pause figures
- `LambLisp_Announcement.pdf` - product announcement
- `LambLisp.pdf` / `html/` - the full reference manual

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
