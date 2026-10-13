//go:build !(android && cgo)

package main

import (
	"github.com/metacubex/mihomo/log"
)

// applySystemDns is a no-op on iOS (the NetworkExtension owns the system
// resolver) and on desktop, where the standalone core manages its own
// resolver and no update channel exists.
func applySystemDns(addr []string) {
	log.Debugln("[DNS] system DNS update ignored (platform manages the resolver)")
}
