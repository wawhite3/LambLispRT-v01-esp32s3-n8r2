// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "ll_platform_generic.h"

#if LL_POSIX

//#include <stdio.h>
//#include <sys/select.h>
#include <termios.h>
#include <sys/ioctl.h>
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

int LambStdioClass::availableForWrite()	{ return true; }      
int LambStdioClass::read(void)		{ return getchar(); }
int LambStdioClass::write(uint8_t c)	{ putchar(c);  return 1; }  
void LambStdioClass::flush(void)	{ fflush(stdout); }

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

#endif

#if LL_ESP32
void LambStdioClass::begin(unsigned long baudrate)
{
  ME("LambStdioClass::begin()");
  Serial.begin(baudrate);
  Serial.printf("[%lu] %s started OK\n", millis(), me);
}

void LambStdioClass::end()			{ Serial.end(); }
int LambStdioClass::setTxBufferSize(int n)	{ return 1; }
int LambStdioClass::setRxBufferSize(int n)	{ return 1; }
int LambStdioClass::available(void)		{ return Serial.available(); }
int LambStdioClass::availableForWrite()		{ return Serial.availableForWrite(); }
void LambStdioClass::flush(void)		{ Serial.flush(); }

int LambStdioClass::write(uint8_t c)		{ Serial.write(c);  return 1; }
int LambStdioClass::read(void)			{ return Serial.read(); }
#endif

LambStdioClass LambStdio;
