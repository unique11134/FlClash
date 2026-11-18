package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"core"
	"unsafe"
)

//export flclash_core_invoke
func flclash_core_invoke(request *C.char) *C.char {
	return C.CString(string(core.IOSInvoke([]byte(C.GoString(request)))))
}

//export flclash_core_event
func flclash_core_event() *C.char {
	data := core.IOSReadEvent()
	if data == nil {
		return nil
	}
	return C.CString(string(data))
}

//export flclash_core_start
func flclash_core_start(ipv4, ipv6 *C.char, mtu C.int32_t) *C.char {
	if err := core.IOSStartPacketFlow(C.GoString(ipv4), C.GoString(ipv6), int(mtu)); err != nil {
		return C.CString(err.Error())
	}
	return nil
}

//export flclash_core_stop
func flclash_core_stop() { core.IOSStopPacketFlow() }

//export flclash_core_network_changed
func flclash_core_network_changed() { core.IOSNetworkChanged() }

//export flclash_core_write_packets
func flclash_core_write_packets(packets *C.uint8_t, length C.int32_t) {
	core.IOSWritePackets(unsafe.Slice((*byte)(packets), int(length)))
}

//export flclash_core_read_packets
func flclash_core_read_packets(packets *C.uint8_t, capacity C.int32_t) C.int32_t {
	return C.int32_t(core.IOSReadPackets(unsafe.Slice((*byte)(packets), int(capacity))))
}

func main() {}
