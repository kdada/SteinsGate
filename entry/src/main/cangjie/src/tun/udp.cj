/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import ohos.hilog.Hilog
import std.collection.ArrayList
import std.collection.none
import std.collection.concurrent.NonBlockingQueue
import std.socket.*
import std.time.Duration

extend IPPacket {
    func udpSrcPort(): UInt16 {
        let headerOffset = headerLength()
        return UInt16(data[headerOffset]) << 8 + UInt16(data[headerOffset + 1])
    }

    func setUdpSrcPort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset] = UInt8(port >> 8)
        data[headerOffset + 1] = UInt8(port)
    }

    func udpDestPort(): UInt16 {
        let headerOffset = headerLength()
        return UInt16(data[headerOffset + 2]) << 8 + UInt16(data[headerOffset + 3])
    }

    func setUdpDestPort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset + 2] = UInt8(port >> 8)
        data[headerOffset + 3] = UInt8(port)
    }

    func udpHeaderLength(): Int64 {
        8
    }

    func udpLength(): Int64 {
        let headerOffset = headerLength()
        return Int64(data[headerOffset + 4]) << 8 + Int64(data[headerOffset + 5])
    }

    func setUdpLength(len: Int64) {
        let headerOffset = headerLength()
        data[headerOffset + 4] = UInt8(len >> 8)
        data[headerOffset + 5] = UInt8(len)
    }

    func updPayload(): Array<UInt8> {
        let headerLen = headerLength() + udpHeaderLength()
        data.slice(headerLen, length() - headerLen)
    }

    func setUdpPayload(payload: Array<UInt8>) {
        payload.copyTo(data, 0, headerLength() + udpHeaderLength(), payload.size)
    }

    func resumUdp() {
        let headerOffset = headerLength()
        data[headerOffset + 6] = 0
        data[headerOffset + 7] = 0
        let result = sumWithPseudoIPHeader(payload())
        data[headerOffset + 6] = UInt8(result >> 8)
        data[headerOffset + 7] = UInt8(result)
    }
}

public interface UdpHandler {
    func canHandle(packet: IPPacket): Bool
    func handle(packet: IPPacket): Unit
}

public class UdpStack <: IPProtocolStack {
    let handlers = ArrayList<UdpHandler>()
    let device: TunDevice
    let pool: IPPacketPool

    public init(device: TunDevice, pool: IPPacketPool) {
        this.device = device
        this.pool = pool
    }

    public override func protocol(): UInt8 {
        return 0x11
    }

    public func register(handler: UdpHandler) {
        handlers.append(handler)
    }

    public override func pop(packet: IPPacket) {
        Hilog.debug(0, "debugTun",
            "UDP: Size: ${packet.length()} From ${packet.srcIPString()} To ${packet.destIPString()}")
        var h: ?UdpHandler = None
        for (handler in handlers) {
            if (handler.canHandle(packet)) {
                h = handler
                break
            }
        }
        if (h.isNone()) {
            packet.release()
        }
        h?.handle(packet)
        return
    }

    public func send(fromIP: Array<UInt8>, fromPort: UInt16, toIP: Array<UInt8>, toPort: UInt16, payload: Array<UInt8>) {
        let packet = pool.getPacket()
        packet.resetIPHeader()
        packet.setProtocol(protocol())
        packet.setSrcIP(fromIP)
        packet.setUdpSrcPort(fromPort)
        packet.setDestIP(toIP)
        packet.setUdpDestPort(toPort)
        packet.setUdpLength(packet.udpHeaderLength() + payload.size)
        packet.setLength(packet.headerLength() + packet.udpHeaderLength() + payload.size)
        packet.setUdpPayload(payload)
        packet.resumIPHeader()
        packet.resumUdp()
        this.device.writePacket(packet)
    }
}

public class DnsHandler <: UdpHandler {
    let server: Array<UInt8>
    let udpStack: UdpStack

    public init(stack: UdpStack, ip: Array<UInt8>) {
        udpStack = stack
        server = ip
    }

    public func canHandle(packet: IPPacket): Bool {
        packet.udpDestPort() == 53
    }

    public func handle(packet: IPPacket): Unit {
        spawn {
            redirectDNSQuery(packet)
        }
        return
    }

    func redirectDNSQuery(packet: IPPacket) {
        try {
            let udp = UdpSocket(bindAt: 0)
            udp.sendTimeout = Duration.second * 30
            udp.bind()
            let payload = packet.updPayload()
            udp.sendTo(SocketAddress(SocketAddressKind.IPv4, server, 53), payload)
            let buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
            let dataSize = udp.receive(buffer)
            if (dataSize <= buffer.size) {
                udpStack.send(packet.destIP(), packet.udpDestPort(), packet.srcIP(), packet.udpSrcPort(),
                    buffer.slice(0, dataSize))
            }
        } finally {
            packet.release()
        }
    }
}
