<!-- Copyright 2026 by Frobenius Norm LLC 2026-09-11 -->
<img src="html/lamb-DALL-01.png" alt="Eponymous Lamb" width="170" align="right"/>

# LambLisp Quick Start

### Real-time *Lisp* for embedded control -- *from AI to actuator*

**LambLisp** by <a href="https://frobeniusnorm.com"><img src="html/FrobeniusNorm-logo-01.png" alt="FrobeniusNorm" style="height:1.2em;vertical-align:middle;display:inline;"/></a> Copyright 2026 <a href="https://frobeniusnorm.com">Frobenius Norm LLC.</a>

<div style="border:1px solid #7fd1b9;border-radius:6px;padding:0.8em 1em;margin:1em 0;">
<b>Nothing to install, two ways.</b> Open <code>demo/index.html</code> from this package to run
<i>LambLisp</i> in your browser, or run the container:
<code>docker run --rm -it ghcr.io/lamblisp/lamblisp:runtime</code> &mdash; it boots straight to the
<code>LL=&gt;</code> prompt. Both are the same interpreter that runs on the board. Come back here
when you want to build.
</div>

---

## 1. What did I get?

Every package is **locked to one target**. `BUILD-INFO` in this directory names it, along with the
exact commit, build date, toolchain and feature flags that produced the binaries -- quote those
lines in any support request.

    head -8 BUILD-INFO

Packages come in two shapes:

| If this directory has... | you have | and you can |
|---|---|---|
| `platformio.ini`, `src/`, `lib/`, `ll_pio/`, `liblamblisp.a` | a **development package** (Linux, or an embedded board) | run the prebuilt binary *and* rebuild from source |
| only `LambLisp.exe` or `LambLisp.bin` with `data/`, `scm/`, `demo/`, `html/` | a **runtime package** (Windows, and other binary-only targets) | run it; build on a Linux development package |

Building and flashing embedded firmware needs a **Linux** host. The container carries the runtime
only -- no toolchain.

---

## 2. Run the prebuilt binary

The binary in this package was built by us, from the commit named in `BUILD-INFO`. Nothing needs
to be compiled to use it.

**Linux**

    ./LambLisp.bin

**Windows** -- from a Command Prompt or PowerShell opened *in this folder*:

    LambLisp.exe

**Embedded** -- `LambLisp.bin` here is ESP32 firmware, not a host program. Flash it (§4) rather
than running it.

> **Run it from this directory.** *LambLisp* loads `data/setup.scm` by a path relative to the
working directory. Started from somewhere else it comes up with no standard library -- the symptom
is a `LL=>` prompt where nearly every procedure is unbound, not an error message about a missing
file. See *Running from any directory* in the manual for how to place it on your `PATH`.

You should see a startup log and then:

    LL=>

Try it:

```scheme
LL=> (+ 1 2)
3
LL=> (define (greet name) (string-append "Hello, " name "!"))
LL=> (greet "world")
"Hello, world!"
```

`Ctrl-C` exits.

---

## 3. Build from source

### Install PlatformIO (once)

*LambLisp* builds with **PlatformIO** (`pio`) on every target -- embedded and host alike.

    curl -fsSL https://raw.githubusercontent.com/platformio/platformio-core-installer/master/get-platformio.py | python3
    ln -s ~/.platformio/penv/bin/pio ~/.local/bin/pio

### Build

    pio run

**There is no `-e` flag to get right.** The `platformio.ini` in this package is locked to this
package's one target with `default_envs`, so the bare command is the whole command -- here, and in
every command below.

Do **not** run `pio pkg install --platform espressif32` first. The `platform =` line in
`platformio.ini` is pinned to a specific release URL and `pio run` installs exactly that; the
command above would fetch a *different*, older platform alongside it.

**What the first build does, so you don't think it has hung.** It downloads a compiler toolchain
and framework -- on the order of a gigabyte, several minutes on a good link, with long silent
stretches. It puts them in `~/.platformio-idf55`, **not** the usual `~/.platformio`, because
`platformio.ini` sets `core_dir` there on purpose: this package needs a specific ESP-IDF, and an
isolated core dir keeps it from colliding with any other PlatformIO project you already have.
Later builds are incremental and quick.

Output lands in `.pio/build/<target>/`.

---

## 4. Flash an embedded board

Connect the board and run **both** of these:

    pio run --target upload         # the firmware
    pio run --target uploadfs       # the data/ filesystem image

**`uploadfs` is not optional, and skipping it does not look like a missing step.** The firmware
loads `setup.scm` and the standard library off the board's LittleFS filesystem at boot; `data/` in
this package *is* that filesystem image. Flash the firmware alone and the board boots to a `LL=>`
prompt with almost nothing defined in it. Either order works. Re-run `uploadfs` on its own whenever
you change a file under `data/`.

PlatformIO finds the serial port itself. If you have more than one board attached, name it:

    pio run --target upload --upload-port /dev/ttyUSB0

Resolve the port at run time -- do not bake a device node into a script. Serial ports are
enumerated dynamically and move between boots and between machines.

> **On the ESP32-S3-DevKitC-1, use the `UART` port, not the `USB` port.** The board has two.
`UART` carries upload and the serial REPL; `USB` is the onboard JTAG debugger. Flashing over the
wrong one fails in a way that reads like a broken board.

### Flashing from a container

You can *build* firmware in a container on any host. You can only *flash* from a Linux host, where
you pass the port in with `--device=/dev/ttyUSB0`. Docker Desktop on macOS and Windows runs your
container inside a virtual machine with **no USB bridge**, so the port simply is not there and
`--target upload` hangs or cannot open it. On those hosts, build in the container if you like and
flash from the host side.

---

## 5. Talk to the board

    pio device monitor

115200 baud, already set in `platformio.ini`. Any terminal emulator works too (`screen`,
`minicom`) on the board's `/dev/ttyUSB*` or `/dev/ttyACM*`.

For anything past a REPL, use the included **LLIP** client, which speaks *LambLisp*'s own
interaction protocol over the same serial line or over TCP:

    tools/llip --serial /dev/ttyUSB0 repl              # line REPL
    tools/llip --serial /dev/ttyUSB0 eval "(+ 1 2)"    # evaluate one form
    tools/llip --serial /dev/ttyUSB0 send app.scm      # push a file to the board
    tools/llip --serial /dev/ttyUSB0 recv log.txt      # pull a file back
    tools/llip --help                                  # everything else

`send` is the fast path while developing: push a changed `.scm` and reload it, with no reflash.

---

## 6. `data/` and `scm/` are not the same thing

| | |
|---|---|
| `data/` | the **filesystem image** for this target -- the subset of the library this board boots with. This is what `uploadfs` writes, and what `setup.scm` finds at startup. |
| `scm/` | the **complete** *LambLisp* Scheme library source, shipped whole with every package regardless of target. Load from it at run time, or copy a file into `data/` and re-run `uploadfs` to boot with it. |

Your application goes in `data/setup.scm`. The file name is fixed; the VM loads it at startup and
calls the procedure `loop` on each cycle. The minimum is:

```scheme
(define (loop)
  ;; your control code here
  )
```

---

## 7. Make it yours

- **Feature set** -- edit `build_flags` in `platformio.ini`. The `-DLL_*` flags select the drivers
  and numeric types compiled in (`LL_I2C`, `LL_WIFI`, `LL_MODBUS`, `LL_BIGNUM`, ...). Dropping what
  you do not use buys flash and RAM. `BUILD-INFO` records the set this package shipped with.
- **Your own C++ primitives** -- `src/` has `main.cpp` and the device drivers, and `lib/` has the
  vendored Arduino libraries. `liblamblisp.a` is the VM itself; the `platformio.ini` links it with
  `-L$PROJECT_DIR -llamblisp`. Adding a *LambLisp* builtin that calls your existing C/C++ code is
  documented in the manual under *Open API for new Lisp primitives*.
- **Do not unpin the platform.** The `platform =` release URL in `platformio.ini` is the only
  in-tree record of which ESP-IDF this was built and measured against. Memory constants in the
  source were measured on that layout.

---

## 8. When it does not work

| What you see | What it is |
|---|---|
| `LL=>` comes up but almost nothing is defined | the filesystem was never flashed -- run `pio run --target uploadfs`, or start the host binary from this directory |
| First build sits silent for minutes | it is downloading the toolchain into `~/.platformio-idf55`. Let it finish. |
| `upload` hangs or cannot open the port | wrong USB port on a DevKitC-1 (use `UART`), a port you do not have permission on (add yourself to the owning `dialout`/`tty` group), or a container on macOS/Windows, which cannot see USB at all |
| Windows reports an unrecognised publisher | `LambLisp.exe` is not code-signed. Choose *More info*, then *Run anyway*. |
| Missing files on the board after a layout change | a flash-partition or memory change presents as **failed reads**, not as an allocation error. Re-check `board_build.partitions`. |

---

## 9. Where to go next

- `LambLisp.pdf` / `html/index.html` -- the full reference manual. Start at *Getting Started*, then
  *Lisp in a nutshell*.
- `LambLisp_ProductBrief.pdf` -- specifications, embedded benchmarks, and measured GC-pause figures.
- `demo/index.html` -- the same interpreter in your browser.
- `BUILD-INFO` -- exactly what this package is.

> **WARNING:** *LambLisp* is in **ALPHA** state. Do not deploy it where life or property may be
endangered.

*LambLisp* is free for non-commercial use. Commercial use requires a license, which brings
customization, application development assistance, post-deployment support, and a warranty.

Thank you for your interest in **LambLisp**.

Bill White -- white3@FrobeniusNorm.com -- [frobeniusnorm.com](https://frobeniusnorm.com)
