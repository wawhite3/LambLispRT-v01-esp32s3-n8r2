// Copyright 2026 by Frobenius Norm LLC 2026-05-16
// Free for non-commercial use. Commercial use requires a license.
#include "LambLisp.h"
//! @defgroup xmop3_wifi WiFi
//! @ingroup xmop3
//! @brief LambLisp WiFi builtins.
//! @{


#if LL_WIFI

WiFiClass *LL_WiFi;

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
Sexpr_t WiFi_mop3_isConnected(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
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

Sexpr_t WiFi_install_mop3(Lamb &lamb, Sexpr_t sexpr, Sexpr_t env_exec)
{
  ME("::WiFi_install_mop3()");
  ll_try {
    lamb.log("%s installing Mops\n", me);
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
