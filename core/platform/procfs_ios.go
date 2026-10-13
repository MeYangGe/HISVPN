//go:build ios

package platform

import "net"

// iOS has no /proc; UID resolution stays with the host callback, which
// reports -1 when the system will not name the owner of a connection.
func QuerySocketUidFromProcFs(_, _ net.Addr) int {
	return -1
}
