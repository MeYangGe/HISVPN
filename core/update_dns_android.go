//go:build android && cgo

package main

import (
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
)

// applySystemDns swaps the resolver mihomo uses for direct connections to
// the VpnService DNS; it exists only on Android, where the framework owns
// the system resolver.
func applySystemDns(addr []string) {
	dns.UpdateSystemDNS(addr)
	dns.FlushCacheWithDefaultResolver()
	log.Debugln("[DNS] system DNS updated (android)")
}
