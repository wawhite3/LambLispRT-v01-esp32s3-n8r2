#!/usr/bin/env python3
# Copyright 2026 by Frobenius Norm LLC 2026-09-21
"""
##$make_pinmap.py.  Render the ESP32-4848S040 board pinout by ANNOTATING Espressif's own
##$  "Figure 3: Pin Layout (Top View)" from the ESP32-S3-WROOM-1 datasheet with this board's net
##$  names.  Writes ESP32-4848S040_pinout.png beside itself.  Needs vendor/ (fetch_docs.sh).

WHY ANNOTATE ESPRESSIF'S FIGURE INSTEAD OF DRAWING ONE.  Three candidate illustrations exist and
only this one is both correct and high quality:

  * Jingcai ships NO pin diagram at all -- the pin map is a 36-row .xlsx and nothing else.
  * Jingcai ships "ESP32-S3-WROOM-1 Pin definition.png", which LOOKS like the answer and is not:
    it is the ESP32-S3-DevKitC-1 DEV BOARD, a different physical object.  This board is a bare
    WROOM-1 soldered to a panel PCB, so the DevKitC's two 22-pin headers are not its footprint.
  * Espressif's datasheet Figure 3 IS the WROOM-1's footprint, is vector (renders at any DPI),
    and is the part actually on this board.

It also shows what a flat pin list destroys: the module has THREE pin rows, not two -- 1-14 left,
15-26 along the BOTTOM edge, 27-40 right.  Twelve of this board's signals (the whole green/red
data group, PCLK, both shared SPI pins and TP_SCL) are on that bottom row.  The vendor's
spreadsheet enumerates them 1..36 in a single column and the bottom row simply vanishes.

PIN NUMBERS HERE ARE THE MODULE'S, NOT THE VENDOR'S.  Jingcai's "Serial Number" 1..36 is its own
enumeration and does NOT agree with Espressif's 1..41 -- e.g. vendor row 1 is IO4, which is module
pin 4.  Cross-reference by GPIO, never by ordinal.
"""
import os, sys, subprocess
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
PDF  = os.path.join(HERE, "vendor/4-Driver_IC_Data_Sheet/esp32-s3-wroom-1_wroom-1u_datasheet_en.pdf")
OUT  = os.path.join(HERE, "ESP32-4848S040_pinout.png")
DPI  = 400                      # Figure 3 is vector; 400 dpi is print quality

# --- palette: one colour per subsystem -------------------------------------------------------
R,G,B      = (200,45,35), (30,130,60), (40,95,200)
SYNC       = (10,135,150)
LCD        = (196,110,10)
TP         = (175,45,140)
SD         = (100,65,185)
UART       = (95,105,120)
AUD        = (135,90,45)
DEAD       = (150,155,165)      # present on the module, unusable on this board
PWR        = (60,65,75)

# --- the board, keyed by MODULE pin number (Espressif Figure 3) -------------------------------
# (net, secondary, colour).  Source: Jingcai "4.0 inches IO pin distribution.xlsx", 36 rows,
# re-keyed from the vendor's ordinal to the module's.
LEFT = {                                     # pins 1..14, top to bottom
  1:("GND",      "",          PWR),
  2:("3V3",      "",          PWR),
  3:("EN",       "",          PWR),
  4:("DB1",      "blue 0",    B),
  5:("DB2",      "blue 1",    B),
  6:("DB3",      "blue 2",    B),
  7:("DB4",      "blue 3",    B),
  8:("DB5",      "blue 4",    B),
  9:("HSYNC",    "",          SYNC),
 10:("VSYNC",    "",          SYNC),
 11:("DE",       "",          SYNC),
 12:("DB6",      "green 0",   G),
 13:("TP_SDA",   "was USB D-",TP),
 14:("DB7",      "green 1",   G),
}
BOTTOM = {                                   # pins 15..26, left to right
 15:("DB8",      "green 2",   G),
 16:("DB9",      "green 3",   G),
 17:("DB10",     "green 4",   G),
 18:("DB11",     "green 5",   G),
 19:("DB13",     "red 0",     R),
 20:("DB14",     "red 1",     R),
 21:("DB15",     "red 2",     R),
 22:("DB16",     "red 3",     R),
 23:("PCLK",     "",          SYNC),
 24:("TF_SDA",   "+LCD MOSI", SD),
 25:("TF_SCK",   "+LCD SCK",  SD),
 26:("TP_SCL",   "",          TP),
}
RIGHT = {                                    # pins 27..40, bottom to top
 27:("DB17",     "red 4/BOOT",R),
 28:("PSRAM",    "octal",     DEAD),
 29:("PSRAM",    "octal",     DEAD),
 30:("PSRAM",    "octal",     DEAD),
 31:("BL_C",     "backlight", LCD),
 32:("LCD_CS",   "init SPI",  LCD),
 33:("I2S_DIN",  "relay L1",  AUD),
 34:("TF_D1",    "MISO",      SD),
 35:("TF_D3",    "CS",        SD),
 36:("RX",       "CH340",     UART),
 37:("TX",       "CH340",     UART),
 38:("I2S_LRCLK","relay L2",  AUD),
 39:("I2S_BCLK", "relay L3",  AUD),
 40:("GND",      "",          PWR),
}

# --- geometry of Figure 3 as rendered at DPI --------------------------------------------------
# Measured on the 400 dpi render of page 9.  Scale linearly if DPI changes.
S       = DPI/400.0
CROP    = (int(560*S), int(1080*S), int(2850*S), int(3700*S))
P1_Y    = 1831*S ; PITCH_V = 119.4*S          # left pin 1 centre, vertical pitch
P15_X   =  979*S ; PITCH_H = 121.0*S          # bottom pin 15 centre, horizontal pitch
ML, MR, MT, MB = int(820*S), int(860*S), int(210*S), int(880*S)
LEAD   = 420          # leader-line length; labels sit LEAD+15 px beyond the figure edge

def font(sz, bold=False):
    f = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/"+f, int(sz*S))

def main():
    if not os.path.exists(PDF):
        sys.exit("missing %s -- run ./fetch_docs.sh first" % PDF)
    base = "/tmp/_wroom_fig"
    subprocess.run(["pdftoppm","-r",str(DPI),"-png","-f","9","-l","9",PDF,base], check=True)
    page = Image.open(base+"-09.png").convert("RGB")
    fig  = page.crop(CROP)

    W = fig.width + ML + MR
    H = fig.height + MT + MB
    img = Image.new("RGB", (W,H), "white")
    img.paste(fig, (ML, MT))
    d = ImageDraw.Draw(img)

    f_net, f_sec, f_ttl, f_sub = font(40,True), font(29), font(64,True), font(31)

    def yc(pin_from_top):                     # pin centre y, in final canvas coords
        return P1_Y - CROP[1] + MT + pin_from_top*PITCH_V
    def xc(i):                                # bottom pin centre x, in final canvas coords
        return P15_X - CROP[0] + ML + i*PITCH_H

    LEDGE = ML - int(30*S)                    # where left leader lines stop
    REDGE = ML + fig.width + int(30*S)
    BEDGE = MT + fig.height + int(40*S)

    for p,(net,sec,col) in LEFT.items():
        y = yc(p-1)
        d.line([(LEDGE-int(LEAD*S), y), (LEDGE, y)], fill=col, width=max(1,int(3*S)))
        w  = d.textlength(net, font=f_net)
        dy = int(50*S) if sec else int(24*S)
        d.text((LEDGE-int((LEAD+15)*S)-w, y-dy), net, font=f_net, fill=col)
        if sec:
            w2 = d.textlength(sec, font=f_sec)
            d.text((LEDGE-int((LEAD+15)*S)-w2, y+int(8*S)), sec, font=f_sec, fill=DEAD)

    for p,(net,sec,col) in RIGHT.items():
        y = yc(40-p)
        d.line([(REDGE, y), (REDGE+int(LEAD*S), y)], fill=col, width=max(1,int(3*S)))
        dy = int(50*S) if sec else int(24*S)
        d.text((REDGE+int((LEAD+15)*S), y-dy), net, font=f_net, fill=col)
        if sec:
            d.text((REDGE+int((LEAD+15)*S), y+int(8*S)), sec, font=f_sec, fill=DEAD)

    for p,(net,sec,col) in BOTTOM.items():
        x = xc(p-15)
        d.line([(x, BEDGE), (x, BEDGE+int(150*S))], fill=col, width=max(1,int(3*S)))
        lbl = net + ("  " + sec if sec else "")
        tw  = int(d.textlength(lbl, font=f_net)) + int(20*S)
        th  = int(52*S)
        strip = Image.new("RGB", (tw, th), "white")
        ImageDraw.Draw(strip).text((0,0), lbl, font=f_net, fill=col)
        strip = strip.rotate(90, expand=True)
        img.paste(strip, (int(x-th/2), BEDGE+int(165*S)))

    d.text((int(60*S), int(30*S)),
           "ESP32-4848S040  --  board nets on the ESP32-S3-WROOM-1 footprint",
           font=f_ttl, fill=(20,20,25))
    d.text((int(60*S), int(102*S)),
           "Drawing: Espressif ESP32-S3-WROOM-1 datasheet v1.1, Figure 3 (vector).   "
           "Nets: Shenzhen Jingcai '4.0 inches IO pin distribution.xlsx', 36 rows.",
           font=f_sub, fill=(90,95,105))
    d.text((int(60*S), int(145*S)),
           "Pin numbers are the MODULE's, not the vendor's ordinal -- cross-reference by GPIO, never "
           "by position in the vendor table.",
           font=f_sub, fill=(90,95,105))
    lx, ly = W-int(820*S), int(38*S)
    for name,col in (("RGB red",R),("RGB green",G),("RGB blue",B),("sync / PCLK",SYNC),
                     ("LCD control",LCD),("GT911 touch",TP),("microSD",SD),
                     ("UART (CH340)",UART),("I2S / relay",AUD),("not board-routed",DEAD)):
        d.rectangle([lx, ly+int(6*S), lx+int(30*S), ly+int(26*S)], fill=col)
        d.text((lx+int(44*S), ly), name, font=f_sec, fill=(45,50,58))
        ly += int(34*S)

    d.text((int(60*S), H-int(95*S)),
           "DB0 and DB12 are absent: an RGB666 panel wired as RGB565, LSB of blue and of red left "
           "unconnected.   IO35/36/37 carry the octal PSRAM -- not spare.   "
           "Documentation, not measurement: nothing has been flashed to this board.",
           font=f_sub, fill=(90,95,105))

    img.save(OUT, optimize=True)
    print("wrote %s  %dx%d  %.1f KB" % (OUT, img.width, img.height, os.path.getsize(OUT)/1024))

if __name__ == "__main__":
    main()
