#ifndef Pins_Arduino_h
#define Pins_Arduino_h

//Pins for the Freenove 4WD robot car.
#include <stdint.h>

static const uint8_t TX0 = 1;
static const uint8_t RX0 = 3;

static const uint8_t SDA = 13;
static const uint8_t SCL = 14;

// Default HW SPI pins -- defaults only, required so the Arduino SPI library
// (ll_xmop3_SPI.cpp, P133) compiles.  Callers pass explicit pins to SPI.begin.
static const uint8_t SS   = 10;
static const uint8_t MOSI = 11;
static const uint8_t SCK  = 12;
static const uint8_t MISO = 9;


//other pins not used in C++ on this device

#endif /* Pins_Arduino_h */
