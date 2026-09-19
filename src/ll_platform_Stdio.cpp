// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "ll_platform_generic.h"

#if LL_POSIX

//#include <stdio.h>
//#include <sys/select.h>
#if LL_TERMIOS
#include <termios.h>
#include <sys/ioctl.h>
#endif
//#include <stropts.h>

void LambStdioClass::begin(unsigned long baudrate)
{
  // Byte-at-a-time I/O.  stdout MUST be unbuffered: write() -> putchar() is otherwise
  // block-buffered when stdout is a PIPE (not a tty), so output only flushes at ~4KB or exit
  // -- a host driving the REPL over a pipe (llip_test_runner subprocess transport) would see
  // nothing until EOF.  This runs unconditionally at startup, unlike the interactive termios
  // setup in available() which the batch-mode (piped-stdin) input path never reaches.
  setbuf(stdout, NULL);
  setbuf(stdin, NULL);
}
void LambStdioClass::end() {}

int LambStdioClass::setTxBufferSize(int n) { return 1; }
int LambStdioClass::setRxBufferSize(int n) { return 1; }
//! POSIX: no transport callback, and none is needed -- stdin is buffered by libc, so the reader
//! never faces the ring-overrun this exists to prevent.  Returning false keeps the caller on its
//! existing path rather than pretending to have armed something.
bool LambStdioClass::set_input_callback(void (*cb)()) { (void) cb; return false; }

int LambStdioClass::availableForWrite()	{ return true; }      
int LambStdioClass::read(void)		{ return getchar(); }
int LambStdioClass::write(uint8_t c)	{ putchar(c);  return 1; }  
void LambStdioClass::flush(void)	{ fflush(stdout); }

#if !LL_TERMIOS
/*! P175: no-termios stdin (wasm32-wasi, and any future host without a raw terminal mode).

  THERE IS NO WAY TO ASK "IS A BYTE WAITING?" HERE.  wasi-libc has no termios.h and no
  FIONREAD ioctl, so the kbhit() trick below cannot be ported -- and there is no partial
  version of it either: a poll() on fd 0 under WASI reports the *file* as readable, not the
  tty as having a keystroke, so it answers "yes" forever and the caller spins.

  So this says "a byte is available" unconditionally and lets read() -> getchar() BLOCK.
  That is correct for the two ways this build is actually driven:
    - piped stdin (the conform/test path), where LL_Term::monitor_commandline() takes its
      line-accumulating branch and never calls available() at all;
    - an interactive wasmtime REPL, where blocking in getchar() at the prompt is exactly
      what a line-oriented REPL should do.
  THE CONSEQUENCE TO KNOW: the line EDITOR (arrow keys, Esc-B/Esc-F, history) needs raw mode
  to see keystrokes one at a time, and cannot work here.  The host terminal stays in cooked
  mode, so LambLisp receives a whole line at a time, already echoed by the terminal.  That is
  a missing feature of this target, not a bug to hunt.
*/
int LambStdioClass::available(void) { return 1; }
#else
int LambStdioClass::available(void) //Credit to: Morgan McGuire, morgan@cs.brown.edu, originally as _kbhit()
{
    static const int STDIN = 0;
    static bool initialized = false;

    if (! initialized) {
      // Use termios to turn off input line buffering
      termios termio;
      tcgetattr(STDIN, &termio);
      termio.c_lflag &= ~ICANON;
      termio.c_lflag &= ~ECHO;
      tcsetattr(STDIN, TCSANOW, &termio);
      setbuf(stdin, NULL);    // stdout is unbuffered in begin() (runs for batch mode too)
      initialized = true;
    }

    int bytesWaiting;
    ioctl(STDIN, FIONREAD, &bytesWaiting);
    return bytesWaiting;
  }
#endif // LL_TERMIOS

#endif

#if LL_ESP32
//! B410: AN RX OVERRUN MUST NOT BE SILENT.  This is the whole point of the fix -- enlarging the ring
//! makes the failure rarer, but only this makes it VISIBLE when it still happens.  Without it a
//! dropped byte leaves an unbalanced expression, the reader waits for a closing paren that the UART
//! threw away, and the board looks hung while being perfectly healthy.  That cost ~15 minutes of
//! diagnosis and a wrong first hypothesis (that a memory-layout change had corrupted the target).
static void ll_stdio_rx_error(hardwareSerial_error_t e)
{
  const char *what = (e == UART_BUFFER_FULL_ERROR) ? "RX ring full"
                   : (e == UART_FIFO_OVF_ERROR)    ? "RX FIFO overflow"
                   : "RX error";
  //! Deliberately terse and on its own line: this fires from the UART event task, and it has to
  //! survive being interleaved with whatever the control loop is printing.
  Serial.printf("\n[%lu] ::LambStdio %s (%d) -- INPUT WAS LOST, the line you sent is incomplete\n",
                millis(), what, (int) e);
}

void LambStdioClass::begin(unsigned long baudrate)
{
  ME("LambStdioClass::begin()");
  //! MUST PRECEDE begin().  HardwareSerial::setRxBufferSize() refuses a resize on a running UART --
  //! it logs "RX Buffer can't be resized when Serial is already running" and returns 0 -- so calling
  //! it after begin() looks like it worked from here and changes nothing.  Check the return.
  //! LL_STDIO_RX_BUFSIZE == 0 means "leave the framework default" -- these rings are internal DRAM
  //! at any size (see the header), so we do not spend from WiFi's account by default.
  //! B425: EVERY HardwareSerial-ONLY CALL NEEDS THE CDC GUARD, not just the one that failed first.
  //! On a native-USB board `Serial` is HWCDC (HardwareSerial.h:441 switches on
  //! ARDUINO_USB_CDC_ON_BOOT) and it has neither setRxBufferSize, onReceiveError nor onReceive.
  //! The build stops at the FIRST such call, so fixing them one at a time just moves the error --
  //! which is exactly what happened here: guarding onReceive revealed onReceiveError one line up.
#if defined(ARDUINO_USB_CDC_ON_BOOT) && ARDUINO_USB_CDC_ON_BOOT
  size_t gotrx = 0;                           //!< HWCDC: no ring to size, and none to report on
#else
  size_t gotrx = LL_STDIO_RX_BUFSIZE ? Serial.setRxBufferSize(LL_STDIO_RX_BUFSIZE) : 0;
  Serial.onReceiveError(ll_stdio_rx_error);   //!< the part of B410's fix that costs nothing
#endif
  Serial.begin(baudrate);
  //! Report what was ACTUALLY obtained, not what was requested.  A silent fallback to the 256-byte
  //! default is exactly the condition this fix exists to remove, and printing the request instead of
  //! the result would hide it again.
  Serial.printf("[%lu] %s started OK (rx ring %s)\n", millis(), me,
                gotrx ? "resized" : "framework default -- internal DRAM, see P208");
}

void LambStdioClass::end()			{ Serial.end(); }
int LambStdioClass::setTxBufferSize(int n)	{ return (int) Serial.setTxBufferSize((size_t) n); }
//! B410: this used to be `{ return 1; }` -- it accepted the call, reported SUCCESS, and did nothing,
//! so every caller believed it had resized a buffer that stayed at the 256-byte default.  A stub
//! that returns success is worse than one that returns failure: it removes the reason to look.
int LambStdioClass::setRxBufferSize(int n)	{ return (int) Serial.setRxBufferSize((size_t) n); }
//! B410: the UART event task calls this, independent of whatever the VM is doing -- which is the
//! point.  Registering it also creates the event task if onReceiveError has not already.
bool LambStdioClass::set_input_callback(void (*cb)())
{
  if (!cb) return false;
#if defined(ARDUINO_USB_CDC_ON_BOOT) && ARDUINO_USB_CDC_ON_BOOT
  //! B410/B425: ON A NATIVE-USB BOARD `Serial` IS `HWCDC`, NOT `HardwareSerial`, AND HWCDC HAS NO
  //! onReceive().  HardwareSerial.h:441 switches the type on ARDUINO_USB_CDC_ON_BOOT, so this is a
  //! COMPILE error and not a runtime one -- `'class HWCDC' has no member named 'onReceive'` -- and
  //! it breaks the build of every env with that flag: esp32-s3-eye is one, which is the same fact
  //! B384 is about (no UART bridge, the USB IS the console).
  //!
  //! Returning false is correct rather than a stopgap.  The caller keeps its reader-driven path,
  //! which is what every board did before the spill reservoir existed, so a CDC board is no worse
  //! off than it was.  It does mean the B410 fix does not reach these boards: the reservoir is
  //! allocated and filled on demand, not ahead of it, so a long paste can still outrun the driver
  //! there.  Say so rather than let a silent `#if` imply coverage that is not there.
  (void) cb;
  return false;
#else
  Serial.onReceive([cb]() { cb(); });
  return true;
#endif
}
int LambStdioClass::available(void)		{ return Serial.available(); }
int LambStdioClass::availableForWrite()		{ return Serial.availableForWrite(); }
void LambStdioClass::flush(void)		{ Serial.flush(); }

int LambStdioClass::write(uint8_t c)		{ Serial.write(c);  return 1; }
int LambStdioClass::read(void)			{ return Serial.read(); }
#endif

LambStdioClass LambStdio;
