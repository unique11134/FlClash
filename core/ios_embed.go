//go:build ios && with_gvisor

package core

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/netip"
	"sync"
	"time"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	tun "github.com/metacubex/sing-tun"
)

const (
	packetQueueSize = 256
	packetBatchSize = 64
	maxPacketSize   = 1500
)

type packetFlowDevice struct {
	endpoint *channel.Endpoint
	stack    tun.Stack
	dns      []string
	cancel   context.CancelFunc
}

var (
	iosFlowMu sync.RWMutex
	iosFlow   *packetFlowDevice
	iosEvents = make(chan []byte, 128)
)

func IOSInvoke(data []byte) []byte {
	var call MethodCall
	if err := json.Unmarshal(data, &call); err != nil {
		return encodeResponse(MethodResponse{Error: asMethodError(err)})
	}
	if call.Method == coreCrashMethod || call.Method == listenerStartMethod || call.Method == listenerStopMethod {
		return encodeResponse(MethodResponse{ID: call.ID, Error: &MethodError{
			Code: "unavailable", Message: "method unavailable in embedded Core",
		}})
	}
	call.seq = methodCallSeq.Add(1)
	return handleMethodCall(&call)
}

func deliverEvent(data []byte) {
	select {
	case iosEvents <- data:
	default:
		select {
		case <-iosEvents:
		default:
		}
		select {
		case iosEvents <- data:
		default:
		}
	}
}

func hasEventListener() bool { return true }

func IOSNetworkChanged() {
	resolver.ResetConnection()
	handleResetNetwork()
	bumpRouteEpoch()
}

func IOSReadEvent() []byte {
	select {
	case data := <-iosEvents:
		return data
	default:
		return nil
	}
}

func IOSStartPacketFlow(ipv4, ipv6 string, mtu int) error {
	iosFlowMu.Lock()
	defer iosFlowMu.Unlock()
	if iosFlow != nil || !handleInitialized() {
		return errors.New("Core is uninitialized or already has a packet flow")
	}
	if mtu < 1280 || mtu > maxPacketSize {
		return errors.New("invalid packet flow MTU")
	}
	v4, err := netip.ParsePrefix(ipv4)
	if err != nil || !v4.Addr().Is4() || !v4.Contains(v4.Addr().Next()) {
		return errors.New("invalid IPv4 packet flow address")
	}
	v6, err := netip.ParsePrefix(ipv6)
	if err != nil || !v6.Addr().Is6() || !v6.Contains(v6.Addr().Next()) {
		return errors.New("invalid IPv6 packet flow address")
	}
	addresses4, addresses6 := []netip.Prefix{v4}, []netip.Prefix{v6}
	dns4, dns6 := v4.Addr().Next(), v6.Addr().Next()
	handler, err := sing.NewListenerHandler(sing.ListenerConfig{Tunnel: tunnel.Tunnel, Type: constant.TUN})
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	device := &packetFlowDevice{
		endpoint: channel.New(packetQueueSize, uint32(mtu), ""),
		dns:      []string{dns4.String(), dns6.String()},
		cancel:   cancel,
	}
	device.stack, err = tun.NewStack("gvisor", tun.StackOptions{
		Context: ctx,
		Tun:     device,
		TunOptions: tun.Options{
			Name: "FlClash", MTU: uint32(mtu), Inet4Address: addresses4, Inet6Address: addresses6,
		},
		UDPTimeout:  2 * time.Minute,
		ICMPTimeout: 10 * time.Second,
		Handler: &sing_tun.ListenerHandler{
			ListenerHandler: handler,
			DnsAddrPorts: []netip.AddrPort{
				netip.AddrPortFrom(dns4, 53), netip.AddrPortFrom(dns6, 53),
			},
			Inet4Address: addresses4, Inet6Address: addresses6, DisableICMPForwarding: true,
		},
		Logger: log.SingLogger,
	})
	if err == nil {
		err = device.stack.Start()
	}
	if err != nil {
		cancel()
		if device.stack != nil {
			_ = device.stack.Close()
		}
		_ = device.Close()
		return err
	}
	resolver.AddSystemDnsBlacklist(device.dns...)
	resolver.ResetConnection()
	iosFlow = device
	setRunning(true)
	bumpRouteEpoch()
	return nil
}

func IOSStopPacketFlow() {
	iosFlowMu.Lock()
	defer iosFlowMu.Unlock()
	if iosFlow != nil {
		iosFlow.cancel()
		_ = iosFlow.stack.Close()
		_ = iosFlow.Close()
		resolver.RemoveSystemDnsBlacklist(iosFlow.dns...)
		iosFlow = nil
	}
	if handleInitialized() {
		handleShutdown()
	}
}

func IOSWritePackets(batch []byte) {
	iosFlowMu.RLock()
	defer iosFlowMu.RUnlock()
	if iosFlow == nil {
		return
	}
	for count := 0; len(batch) >= 2 && count < packetBatchSize; count++ {
		size := int(binary.BigEndian.Uint16(batch))
		batch = batch[2:]
		if size < header.IPv4MinimumSize || size > maxPacketSize || size > len(batch) {
			return
		}
		packet := batch[:size]
		batch = batch[size:]
		var protocol = header.IPv4ProtocolNumber
		switch packet[0] >> 4 {
		case 4:
		case 6:
			if size < header.IPv6MinimumSize {
				continue
			}
			protocol = header.IPv6ProtocolNumber
		default:
			continue
		}
		input := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
		iosFlow.endpoint.InjectInbound(protocol, input)
		input.DecRef()
	}
}

func IOSReadPackets(batch []byte) int {
	iosFlowMu.RLock()
	defer iosFlowMu.RUnlock()
	if iosFlow == nil {
		return 0
	}
	size := 0
	for range packetBatchSize {
		if len(batch)-size < maxPacketSize+2 {
			break
		}
		packet := iosFlow.endpoint.Read()
		if packet == nil {
			break
		}
		view := packet.ToView()
		packet.DecRef()
		if length := view.Size(); length <= maxPacketSize {
			binary.BigEndian.PutUint16(batch[size:], uint16(length))
			size += 2 + copy(batch[size+2:], view.AsSlice())
		}
		view.Release()
	}
	return size
}

func (d *packetFlowDevice) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	return d.endpoint, stack.NICOptions{}, nil
}

func (d *packetFlowDevice) Read([]byte) (int, error) {
	return 0, errors.New("packet flow uses a gVisor link endpoint")
}

func (d *packetFlowDevice) Write([]byte) (int, error) {
	return 0, errors.New("packet flow uses a gVisor link endpoint")
}

func (d *packetFlowDevice) WritePacket(packet *stack.PacketBuffer) (int, error) {
	var packets stack.PacketBufferList
	packets.PushBack(packet)
	n, err := d.endpoint.WritePackets(packets)
	if err != nil {
		return 0, errors.New(err.String())
	}
	if n == 0 {
		return 0, errors.New("packet flow queue is full")
	}
	return packet.Size(), nil
}

func (d *packetFlowDevice) Close() error {
	d.endpoint.Close()
	return nil
}
