// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"
#include "ll_fastram.h"   //!< P211: reserve the radio's DRAM at install time
//! @defgroup xmop3_wifi WiFi
//! @ingroup xmop3
//! @brief LambLisp WiFi builtins.
//! @{


#if LL_WIFI

//! POINT THIS AT THE ARDUINO GLOBAL.  It was declared and NEVER ASSIGNED anywhere in the
//! repo -- so it was a NULL pointer, and every one of the ~40 `LL_WiFi->` call sites below
//! dereferenced null.  It did not look like that from the crash:
//!     Guru Meditation Error: Core 1 panic'ed (LoadProhibited), EXCVADDR 0x00000008
//!       NetworkInterface::getStatusBits()  NetworkInterface.cpp:231
//!       WiFiSTAClass::isConnected()        WiFiSTA.cpp:222
//! which reads as an Arduino 3.x defect -- a "null netif in the new NetworkInterface layer" -- and
//! was first diagnosed that way.  It is ours.  `STAClass STA` is a MEMBER of WiFiSTAClass, so with
//! `this == nullptr` the call reaches `_interface_event_group` at offset 8 of a null object: that
//! IS the 0x00000008 in the report.  getStatusBits() already null-checks its event group, so a
//! real object cannot panic there.
//! WHY IT SURVIVED ARDUINO 2.0.17: `isConnected()` there read a global and touched no member, so
//! calling it through a null `this` was undefined but harmless in practice.  Arduino 3.x moved
//! status behind a member, and the latent null became a reboot.  So this is a migration TRIGGER,
//! not a migration regression -- the defect predates it.
//! Constant-initialised: `&WiFi` is a link-time address, so this does not depend on WiFi's
//! constructor having run (no static-init-order hazard); the calls all happen after setup().
//! Fixing it HERE fixes all ~40 sites at once, which per-site readiness guards would not.
WiFiClass *LL_WiFi = &WiFi;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/*! Parse a Scheme string like "192.168.1.1" into an Arduino IPAddress.
    Returns IPAddress(0) (INADDR_ANY) if the arg is #f or NIL. */
static IPAddress parse_ip(Sexpr_t sx)
{
  IPAddress addr((uint32_t) 0);
  if (sx != NIL && sx != HASHF) addr.fromString(sx->any_str_get_chars());
  return addr;
}

// ---------------------------------------------------------------------------
// STA -- connection management
// ---------------------------------------------------------------------------

//! Connect to an access point with SSID and optional password; returns wl_status_t.
Sexpr_t WiFi_mop3_begin(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_begin()");
  ll_try {
    Charst_t id = lamb.car(sexpr)->any_str_get_chars();
    Sexpr_t  r  = lamb.cdr(sexpr);
    Charst_t pw = (r != NIL) ? lamb.car(r)->any_str_get_chars() : nullptr;
    //! P211: HAND THE RESERVATION BACK IMMEDIATELY BEFORE THE RADIO CLAIMS, so the stack lands in
    //! the hole taken at install time rather than in whatever the .scm load chain has left.  Same
    //! shape as EyeCam's camera hole.  Nothing allocates internal DRAM between here and begin().
    ll_fastram_release("wifi");
    return lamb.mk_integer(LL_WiFi->begin(id, pw), env_exec);
  }
  ll_catch();
}

//! Disconnect from WiFi; optional args wifioff and eraseap.
Sexpr_t WiFi_mop3_disconnect(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  bool wifioff = false, eraseap = false;
  if (sexpr != NIL) { wifioff = (lamb.car(sexpr) != HASHF);  sexpr = lamb.cdr(sexpr); }
  if (sexpr != NIL)   eraseap = (lamb.car(sexpr) != HASHF);
  return lamb.mk_bool(LL_WiFi->disconnect(wifioff, eraseap), env_exec);
}

//! Reconnect to the last access point; returns #t on success.
Sexpr_t WiFi_mop3_reconnect(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  return lamb.mk_bool(LL_WiFi->reconnect(), env_exec);
}

//! Set static IP configuration; all args are IP strings or #f for INADDR_ANY.
Sexpr_t WiFi_mop3_config(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_config()");
  ll_try {
    IPAddress ip      = parse_ip(lamb.car(sexpr));                 sexpr = lamb.cdr(sexpr);
    IPAddress gw      = (sexpr != NIL) ? parse_ip(lamb.car(sexpr)) : IPAddress((uint32_t) 0);
    if (sexpr != NIL) sexpr = lamb.cdr(sexpr);
    IPAddress subnet  = (sexpr != NIL) ? parse_ip(lamb.car(sexpr)) : IPAddress((uint32_t) 0);
    if (sexpr != NIL) sexpr = lamb.cdr(sexpr);
    IPAddress dns1    = (sexpr != NIL) ? parse_ip(lamb.car(sexpr)) : IPAddress((uint32_t) 0);
    if (sexpr != NIL) sexpr = lamb.cdr(sexpr);
    IPAddress dns2    = (sexpr != NIL) ? parse_ip(lamb.car(sexpr)) : IPAddress((uint32_t) 0);
    return lamb.mk_bool(LL_WiFi->config(ip, gw, subnet, dns1, dns2), env_exec);
  }
  ll_catch();
}

//! Reconfigure DNS servers without changing IP/GW/subnet.
Sexpr_t WiFi_mop3_setDNS(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_setDNS()");
  ll_try {
    IPAddress dns1 = parse_ip(lamb.car(sexpr));
    IPAddress dns2 = (lamb.cdr(sexpr) != NIL) ? parse_ip(lamb.cadr(sexpr)) : IPAddress((uint32_t) 0);
    bool ok = LL_WiFi->config(LL_WiFi->localIP(), LL_WiFi->gatewayIP(),
                              LL_WiFi->subnetMask(), dns1, dns2);
    return lamb.mk_bool(ok, env_exec);
  }
  ll_catch();
}

//! Block until connected or timeout (default 60000 ms); returns wl_status_t integer.
Sexpr_t WiFi_mop3_waitForConnectResult(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  unsigned long ms = (sexpr != NIL) ? (unsigned long) lamb.car(sexpr)->as_int32() : 60000UL;
  return lamb.mk_integer(LL_WiFi->waitForConnectResult(ms), env_exec);
}

//! Return #t if currently connected to an access point.
//! IS THE STA INTERFACE UP ENOUGH TO BE ASKED FOR STATUS?
//!
//! Arduino 3.x routes WiFi status through the new NetworkInterface layer, and
//! NetworkInterface::getStatusBits() DEREFERENCES A NULL netif when the interface was never
//! started -- Guru Meditation LoadProhibited, EXCVADDR 0x00000008, and the board REBOOTS.  Under
//! Arduino 2.0.17 the same call was safe, so this is a MIGRATION REGRESSION, not a latent
//! bug.  The reboot is nastier than a failed test: it happens while a .scm file is loading, so the
//! harness sees a restarting board rather than a red cell -- an absent result reads as "nothing
//! ran" instead of "this broke".
//!
//! getMode() is the safe probe: it asks esp_wifi for the configured mode and answers WIFI_MODE_NULL
//! before init rather than walking a netif.  The guard belongs HERE and not in Scheme: net-bound?
//! only proves the symbol exists, and the Scheme layer cannot see whether the netif is live.
//!
//! STILL UNAUDITED, and do not assume otherwise: this file has ~40 LL_WiFi-> call sites and only
//! isConnected() is a CONFIRMED panic.  Every call that reads status or an address before begin()
//! is a candidate -- status(), localIP(), gatewayIP(), subnetMask(), subnetCIDR(), SSID(), and the
//! softAP* family (which would need an AP-mode probe, not this one).  Guarded below are the two
//! that were reproduced or are the direct equivalent; the rest are left ALONE deliberately rather
//! than blind-edited on hardware I cannot test, and this helper is here for whoever audits them.
static bool ll_wifi_sta_ready()
{
#if LL_ESP32
  const wifi_mode_t m = LL_WiFi->getMode();
  return (m == WIFI_MODE_STA || m == WIFI_MODE_APSTA);
#else
  return true;                                  //!< host/LLArduino build: nothing to panic on
#endif
}

Sexpr_t WiFi_mop3_isConnected(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  //! NOT STARTED IS NOT CONNECTED.  A predicate named `isConnected` must answer the question,
  //! never abort the VM -- returning #f here is both correct and what any caller expects.
  if (!ll_wifi_sta_ready()) return HASHF;
  return lamb.mk_bool(LL_WiFi->isConnected(), env_exec);
}

//! Enable or disable automatic reconnection; optional arg defaults to #t (enable).
Sexpr_t WiFi_mop3_setAutoReconnect(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  bool en = (sexpr == NIL) || (lamb.car(sexpr) != HASHF);
  return lamb.mk_bool(LL_WiFi->setAutoReconnect(en), env_exec);
}

// ---------------------------------------------------------------------------
// STA -- network info
// ---------------------------------------------------------------------------

//! Return the SSID of the connected access point as a string.
Sexpr_t WiFi_mop3_SSID(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->SSID().c_str()); }

//! Return the BSSID (AP MAC address) as a colon-separated hex string.
Sexpr_t WiFi_mop3_BSSID(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->BSSIDstr().c_str()); }

//! Return the received signal strength in dBm.
Sexpr_t WiFi_mop3_RSSI(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_integer(LL_WiFi->RSSI(), env_exec); }

//! Return the local IP address as a dotted-decimal string.
Sexpr_t WiFi_mop3_localIP(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->localIP().toString().c_str()); }

//! Return the subnet mask as a dotted-decimal string.
Sexpr_t WiFi_mop3_subnetMask(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->subnetMask().toString().c_str()); }

//! Return the gateway IP address as a dotted-decimal string.
Sexpr_t WiFi_mop3_gatewayIP(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->gatewayIP().toString().c_str()); }

//! Return the broadcast IP address as a dotted-decimal string.
Sexpr_t WiFi_mop3_broadcastIP(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->broadcastIP().toString().c_str()); }

//! Return the network base address as a dotted-decimal string.
Sexpr_t WiFi_mop3_networkID(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->networkID().toString().c_str()); }

//! Return the DNS server IP string; optional arg n selects primary (0) or secondary (1).
Sexpr_t WiFi_mop3_dnsIP(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  uint8_t n = (sexpr != NIL) ? (uint8_t) lamb.car(sexpr)->as_int32() : 0;
  return lamb.mk_string(env_exec, LL_WiFi->dnsIP(n).toString().c_str());
}

//! Return the subnet prefix length as an integer (CIDR notation).
Sexpr_t WiFi_mop3_subnetCIDR(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_integer(LL_WiFi->subnetCIDR(), env_exec); }

//! Return the WPA/WPA2 pre-shared key as a string.
Sexpr_t WiFi_mop3_psk(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->psk().c_str()); }

//! Return the station MAC address as a colon-separated hex string.
Sexpr_t WiFi_mop3_macAddress(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->macAddress().c_str()); }

//! Return the encryption type of the connected network as an integer.
Sexpr_t WiFi_mop3_encryptionType(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_encryptionType()");
  ll_try {
    byte ifc = (sexpr != NIL) ? (byte) lamb.car(sexpr)->as_int32() : 0;
    return lamb.mk_integer(LL_WiFi->encryptionType(ifc), env_exec);
  }
  ll_catch();
}

// ---------------------------------------------------------------------------
// STA -- status
// ---------------------------------------------------------------------------

//! Return a list (status-int status-string) describing the current WiFi connection state.
Sexpr_t WiFi_mop3_status(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  //! status() reads the same NetworkInterface state isConnected() does, so it is the direct
  //! equivalent and gets the same guard.  WL_NO_SHIELD is the honest answer for "no interface".
  if (!ll_wifi_sta_ready())
    return lamb.cons(lamb.mk_integer(WL_NO_SHIELD, env_exec),
                     lamb.cons(lamb.mk_string("WL_NO_SHIELD", env_exec), NIL, env_exec), env_exec);
  LL_int32     stat = LL_WiFi->status();
  Charst_t  msg  = "WL_UNKNOWN";
  switch (stat) {
  case WL_NO_SHIELD:      msg = "WL_NO_SHIELD";      break;
  case WL_IDLE_STATUS:    msg = "WL_IDLE_STATUS";     break;
  case WL_NO_SSID_AVAIL:  msg = "WL_NO_SSID_AVAIL";  break;
  case WL_SCAN_COMPLETED: msg = "WL_SCAN_COMPLETED";  break;
  case WL_CONNECTED:      msg = "WL_CONNECTED";       break;
  case WL_CONNECT_FAILED: msg = "WL_CONNECT_FAILED";  break;
  case WL_CONNECTION_LOST:msg = "WL_CONNECTION_LOST"; break;
  case WL_DISCONNECTED:   msg = "WL_DISCONNECTED";    break;
  }
  Sexpr_t res    = NIL;
  Sexpr_t sx_msg = lamb.mk_string(env_exec, msg);
  res = lamb.cons(sx_msg, res, env_exec);
  Sexpr_t sx_stat = NIL;
  mop3_gc_protect(res, {
      sx_stat = lamb.mk_integer(stat, env_exec);
  });
  return lamb.cons(sx_stat, res, env_exec);
}

// ---------------------------------------------------------------------------
// Generic -- mode, hostname, sleep, scan
// ---------------------------------------------------------------------------

//! Set WiFi mode: 0=NULL 1=STA 2=AP 3=APSTA; returns #t on success.
Sexpr_t WiFi_mop3_mode(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_mode()");
  ll_try {
    wifi_mode_t m = (wifi_mode_t) lamb.car(sexpr)->as_int32();
    return lamb.mk_bool(LL_WiFi->mode(m), env_exec);
  }
  ll_catch();
}

//! Return the mDNS hostname as a string.
Sexpr_t WiFi_mop3_getHostname(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  const char *h = LL_WiFi->getHostname();
  return lamb.mk_string(env_exec, h ? h : "");
}

//! Set the mDNS hostname; returns #t on success.
Sexpr_t WiFi_mop3_setHostname(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_setHostname()");
  ll_try {
    Charst_t name = lamb.car(sexpr)->any_str_get_chars();
    return lamb.mk_bool(LL_WiFi->setHostname(name), env_exec);
  }
  ll_catch();
}

//! Set power-save sleep mode: #t/#f or integer 0=none 1=modem 2=light.
Sexpr_t WiFi_mop3_setSleep(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_setSleep()");
  ll_try {
    Sexpr_t arg = lamb.car(sexpr);
    bool ok;
    if (arg->type() == Cell::T_INT32) {
      ok = LL_WiFi->setSleep((wifi_ps_type_t) arg->as_int32());
    }
    else {
      ok = LL_WiFi->setSleep(arg != HASHF);
    }
    return lamb.mk_bool(ok, env_exec);
  }
  ll_catch();
}

//! Return the current WiFi channel number.
Sexpr_t WiFi_mop3_channel(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_integer(LL_WiFi->channel(), env_exec); }

//! Scan for nearby networks and return the count found.
Sexpr_t WiFi_mop3_scanNetworks(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_integer(LL_WiFi->scanNetworks(), env_exec); }

//! Resolve a hostname to an IP string; returns #f on failure.
Sexpr_t WiFi_mop3_hostByName(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_hostByName()");
  ll_try {
    Charst_t host = lamb.car(sexpr)->any_str_get_chars();
    IPAddress addr;
    if (WiFiGenericClass::hostByName(host, addr))
      return lamb.mk_string(env_exec, addr.toString().c_str());
    return HASHF;
  }
  ll_catch();
}

// ---------------------------------------------------------------------------
// Soft-AP
// ---------------------------------------------------------------------------

//! Start a soft access point with SSID and optional password/channel/hidden/max-conn.
Sexpr_t WiFi_mop3_softAP(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_softAP()");
  ll_try {
    Charst_t ssid    = lamb.car(sexpr)->any_str_get_chars();             sexpr = lamb.cdr(sexpr);
    Charst_t pass    = (sexpr != NIL) ? lamb.car(sexpr)->any_str_get_chars() : nullptr;
    if (sexpr != NIL) sexpr = lamb.cdr(sexpr);
    int channel      = (sexpr != NIL) ? (int) lamb.car(sexpr)->as_int32() : 1;
    if (sexpr != NIL) sexpr = lamb.cdr(sexpr);
    int hidden       = (sexpr != NIL) ? (int) lamb.car(sexpr)->as_int32() : 0;
    if (sexpr != NIL) sexpr = lamb.cdr(sexpr);
    int max_conn     = (sexpr != NIL) ? (int) lamb.car(sexpr)->as_int32() : 4;
    return lamb.mk_bool(LL_WiFi->softAP(ssid, pass, channel, hidden, max_conn), env_exec);
  }
  ll_catch();
}

//! Set soft-AP IP configuration; ip, gateway, subnet are dotted-decimal strings.
Sexpr_t WiFi_mop3_softAPConfig(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_softAPConfig()");
  ll_try {
    IPAddress ip     = parse_ip(lamb.car(sexpr));   sexpr = lamb.cdr(sexpr);
    IPAddress gw     = parse_ip(lamb.car(sexpr));   sexpr = lamb.cdr(sexpr);
    IPAddress subnet = parse_ip(lamb.car(sexpr));
    return lamb.mk_bool(LL_WiFi->softAPConfig(ip, gw, subnet), env_exec);
  }
  ll_catch();
}

//! Shut down the soft-AP; optional arg wifioff also disables the radio.
Sexpr_t WiFi_mop3_softAPdisconnect(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  bool wifioff = (sexpr != NIL) && (lamb.car(sexpr) != HASHF);
  return lamb.mk_bool(LL_WiFi->softAPdisconnect(wifioff), env_exec);
}

//! Return the number of stations currently connected to the soft-AP.
Sexpr_t WiFi_mop3_softAPgetStationNum(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_integer(LL_WiFi->softAPgetStationNum(), env_exec); }

//! Return the soft-AP IP address as a dotted-decimal string.
Sexpr_t WiFi_mop3_softAPIP(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->softAPIP().toString().c_str()); }

//! Return the soft-AP broadcast IP address as a dotted-decimal string.
Sexpr_t WiFi_mop3_softAPBroadcastIP(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->softAPBroadcastIP().toString().c_str()); }

//! Return the soft-AP SSID as a string.
Sexpr_t WiFi_mop3_softAPSSID(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->softAPSSID().c_str()); }

//! Return the soft-AP MAC address as a colon-separated hex string.
Sexpr_t WiFi_mop3_softAPmacAddress(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
  { return lamb.mk_string(env_exec, LL_WiFi->softAPmacAddress().c_str()); }

//! Return the soft-AP mDNS hostname as a string.
Sexpr_t WiFi_mop3_softAPgetHostname(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  const char *h = LL_WiFi->softAPgetHostname();
  return lamb.mk_string(env_exec, h ? h : "");
}

//! Set the soft-AP mDNS hostname; returns #t on success.
Sexpr_t WiFi_mop3_softAPsetHostname(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_mop3_softAPsetHostname()");
  ll_try {
    Charst_t name = lamb.car(sexpr)->any_str_get_chars();
    return lamb.mk_bool(LL_WiFi->softAPsetHostname(name), env_exec);
  }
  ll_catch();
}

#endif  // LL_WIFI

// ---------------------------------------------------------------------------
// Installer
// ---------------------------------------------------------------------------


#if LL_WIFI && LL_ESP32
//! P211: WILL THIS BOARD ACTUALLY RAISE A RADIO?  Answered HERE, in the installer, because the
//! reservation is made here and a speculative reservation is not free.
//!
//! WHY THIS IS NOT "PARSING SCHEME IN C++": it is not evaluating anything.  setup.scm reads
//! Settings.scm and then Settings-local.scm (which OVERRIDES it -- setup.scm:120-129) long after
//! this point, and `(setting 'wifi 0)` is a plain assq over the result.  All we need is the value
//! of one key, and LittleFS is already mounted (ll_heap_note("after LittleFS.begin") precedes the
//! installer loop), so we read the file and look for it.
//!
//! IT FAILS TOWARD TODAY'S BEHAVIOUR.  Cannot open the file, cannot find the key, cannot parse the
//! value -> return false -> NO reservation -> the radio allocates exactly as it did before this
//! proposal existed.  A wrong answer costs ordering quality; it can never cost correctness.  That
//! matters because the cost of guessing WRONG is measured and asymmetric: on Freenove-ESP32-WROVER,
//! reserving 48 KB for a radio that never starts pushed the NCG exec pool's 32 KB claim into a
//! 14,324-byte largest block, it failed, and the board ran `NCG 0  BC 191` -- it gave up native
//! code entirely to hold memory for a radio it does not use.
//!
//! KEEP IN STEP WITH scm/core/WiFi.scm:19, which is the other half of this decision:
//!     (when (positive? (setting 'wifi 0)) (WiFi.begin ...))
//! If that guard changes, this must change with it.  Two readers of one key is a drift risk, and
//! the mitigation is that this one fails safe while that one is authoritative.
static bool ll_wifi_wanted_at_boot()
{
  //! PATHS ARE MOUNT-RELATIVE, AND `ll_file_system` IS THE ONLY CORRECT WAY TO SAY SO.
  //! ll_lfs_abspath() (ll_vm_file.cpp:37) prepends "/" and NOTHING ELSE -- the Arduino LittleFS
  //! object's paths are already relative to its "/littlefs" mount point.  A first version of this
  //! opened "/littlefs/Settings.scm" through raw LittleFS, which can never exist: it would have
  //! returned false forever, reserved nothing, and looked exactly like a board that does not use
  //! WiFi.  Going through ll_file_system also gets the lazy mount (ll_lfs_ensure_mounted) that raw
  //! LittleFS.open does not.
  const char *files[] = { "Settings-local.scm", "Settings.scm" };   //!< local OVERRIDES the default
  for (unsigned f = 0; f < sizeof(files)/sizeof(files[0]); f++) {
    if (!ll_file_system.exists(files[f])) continue;
    LL_File *fh = ll_file_system.open(files[f], "r");
    if (!fh) continue;
    char buf[1024];
    int n = fh->read(buf, (int) sizeof(buf) - 1);
    fh->close();
    delete fh;
    if (n < 0) n = 0;
    buf[n] = 0;
    //! Look for `(wifi` then the first digit after it.  `(wifi_ssid . "...")` must NOT match, so
    //! require the next char after the key to be space or dot -- wifi_ssid fails on the underscore.
    for (char *p = buf; (p = strstr(p, "(wifi")) != nullptr; p += 5) {
      char c = p[5];
      if (c != ' ' && c != '\t' && c != '.') continue;          //!< (wifi_ssid ... -> skip
      for (char *q = p + 5; *q && *q != ')'; q++)
        if (*q >= '0' && *q <= '9') return (*q != '0');          //!< first digit decides
    }
  }
  return false;                                                  //!< unknown -> do not speculate
}
#endif

Sexpr_t WiFi_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
#if LL_WIFI
    //! P211 PHASE 1: CLAIM THE RADIO'S FAST RAM HERE, NOT WHERE WiFi.scm HAPPENS TO RUN.
    //! Measured on esp32-s3-eye: the `when` form in WiFi.scm costs 48,752 bytes and takes the
    //! largest contiguous block from 69,620 to 31,732 -- mid-way through the .scm chain, after
    //! every earlier claimant has already budgeted against a number that is about to be wrong.
    //! Reserving at install time means the claim lands while the pool is whole, and the barrier
    //! after the installer loop reports a remainder a later claimant can actually trust.
    //! RELEASED THREE WAYS: to WiFi.begin() if the radio starts, by the unclaimed sweep after
    //! setup.scm if it does not, and not at all if the reserve could not be met (best-effort).
#if LL_ESP32
    if (ll_wifi_wanted_at_boot()) {
      ll_fastram_reserve("wifi", LL_WIFI_RESERVE_BYTES);
    } else {
      global_printf("[fastram] wifi NOT reserved -- this board does not auto-connect at boot\n");
    }
#endif
#endif
    Sexpr_t env_target = lamb.car(sexpr);
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } base_procs[] = {
      { WiFi_install_mop3, "WiFi.install-mop3", false },
    };
    const int Nbase_procs = sizeof(base_procs)/sizeof(base_procs[0]);
    for (int i = 0; i < Nbase_procs; i++) {
      const auto &p = base_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#if LL_WIFI
    static const struct { Lamb::Mop3st_t func; const char *name; bool syntax; } wifi_procs[] = {
// STA -- connection
      { WiFi_mop3_begin,                "WiFi.begin",                false },
      { WiFi_mop3_disconnect,           "WiFi.disconnect",           false },
      { WiFi_mop3_reconnect,            "WiFi.reconnect",            false },
      { WiFi_mop3_config,               "WiFi.config",               false },
      { WiFi_mop3_setDNS,               "WiFi.setDNS",               false },
      { WiFi_mop3_waitForConnectResult, "WiFi.waitForConnectResult", false },
      { WiFi_mop3_isConnected,          "WiFi.isConnected",          false },
      { WiFi_mop3_setAutoReconnect,     "WiFi.setAutoReconnect",     false },
// STA -- network info
      { WiFi_mop3_SSID,                 "WiFi.SSID",                 false },
      { WiFi_mop3_BSSID,                "WiFi.BSSID",                false },
      { WiFi_mop3_RSSI,                 "WiFi.RSSI",                 false },
      { WiFi_mop3_localIP,              "WiFi.localIP",              false },
      { WiFi_mop3_subnetMask,           "WiFi.subnetMask",           false },
      { WiFi_mop3_gatewayIP,            "WiFi.gatewayIP",            false },
      { WiFi_mop3_broadcastIP,          "WiFi.broadcastIP",          false },
      { WiFi_mop3_networkID,            "WiFi.networkID",            false },
      { WiFi_mop3_dnsIP,                "WiFi.dnsIP",                false },
      { WiFi_mop3_subnetCIDR,           "WiFi.subnetCIDR",           false },
      { WiFi_mop3_psk,                  "WiFi.psk",                  false },
      { WiFi_mop3_macAddress,           "WiFi.macAddress",           false },
      { WiFi_mop3_encryptionType,       "WiFi.encryptionType",       false },
      { WiFi_mop3_status,               "WiFi.status",               false },
// Generic
      { WiFi_mop3_mode,                 "WiFi.mode",                 false },
      { WiFi_mop3_getHostname,          "WiFi.getHostname",          false },
      { WiFi_mop3_setHostname,          "WiFi.setHostname",          false },
      { WiFi_mop3_setSleep,             "WiFi.setSleep",             false },
      { WiFi_mop3_channel,              "WiFi.channel",              false },
      { WiFi_mop3_scanNetworks,         "WiFi.scanNetworks",         false },
      { WiFi_mop3_hostByName,           "WiFi.hostByName",           false },
// Soft-AP
      { WiFi_mop3_softAP,               "WiFi.softAP",               false },
      { WiFi_mop3_softAPConfig,         "WiFi.softAPConfig",         false },
      { WiFi_mop3_softAPdisconnect,     "WiFi.softAPdisconnect",     false },
      { WiFi_mop3_softAPgetStationNum,  "WiFi.softAPgetStationNum",  false },
      { WiFi_mop3_softAPIP,             "WiFi.softAPIP",             false },
      { WiFi_mop3_softAPBroadcastIP,    "WiFi.softAPBroadcastIP",    false },
      { WiFi_mop3_softAPSSID,           "WiFi.softAPSSID",           false },
      { WiFi_mop3_softAPmacAddress,     "WiFi.softAPmacAddress",     false },
      { WiFi_mop3_softAPgetHostname,    "WiFi.softAPgetHostname",    false },
      { WiFi_mop3_softAPsetHostname,    "WiFi.softAPsetHostname",    false },
    };
    const int Nwifi_procs = sizeof(wifi_procs)/sizeof(wifi_procs[0]);
    lamb.log("%s defining %d Mops\n", me, Nwifi_procs);
    for (int i = 0; i < Nwifi_procs; i++) {
      const auto &p = wifi_procs[i];
      Sexpr_t proc = lamb.mk_Mop3_procst_t(p.func, env_exec);
      mop3_gc_protect(proc, {
          Sexpr_t sym = lamb.mk_symbol(p.name, env_exec);
          lamb.dict_bind_bang(env_target, sym, proc, env_exec);
      });
    }
#endif
    return NIL;
  }
  ll_catch();
}
//! @}
