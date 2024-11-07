/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import ohos.hilog.Hilog
import std.collection.*
import std.collection.concurrent.NonBlockingQueue
import std.socket.*
import std.time.Duration

extend IPPacket {
    func udpSourcePort(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset]) << 8) + UInt16(data[headerOffset + 1])
    }

    @OverflowWrapping
    func setUdpSourcePort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset] = UInt8(port >> 8)
        data[headerOffset + 1] = UInt8(port)
    }

    func udpDestinationPort(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset + 2]) << 8) + UInt16(data[headerOffset + 3])
    }

    @OverflowWrapping
    func setUdpDestinationPort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset + 2] = UInt8(port >> 8)
        data[headerOffset + 3] = UInt8(port)
    }

    func udpHeaderLength(): Int64 {
        8
    }

    func udpLength(): Int64 {
        let headerOffset = headerLength()
        return (Int64(data[headerOffset + 4]) << 8) + Int64(data[headerOffset + 5])
    }

    @OverflowWrapping
    func setUdpLength(len: Int64) {
        let headerOffset = headerLength()
        data[headerOffset + 4] = UInt8(len >> 8)
        data[headerOffset + 5] = UInt8(len)
    }

    func udpPayload(): Array<UInt8> {
        let headerLen = headerLength() + udpHeaderLength()
        data.slice(headerLen, length() - headerLen)
    }

    func setUdpPayload(payload: Array<UInt8>) {
        payload.copyTo(data, 0, headerLength() + udpHeaderLength(), payload.size)
    }

    @OverflowWrapping
    func resumUdp() {
        let headerOffset = headerLength()
        data[headerOffset + 6] = 0
        data[headerOffset + 7] = 0
        let result = sumWithPseudoIPHeader(payload())
        data[headerOffset + 6] = UInt8(result >> 8)
        data[headerOffset + 7] = UInt8(result)
    }

    func validateUdp(): Bool {
        sumWithPseudoIPHeader(payload()) == 0
    }
}

extend IPPacket {
    func dnsHeaderLength(): Int64 {
        12
    }

    func dnsQuestionCount(): Int64 {
        let headerOffset = headerLength() + udpHeaderLength()
        return (Int64(data[headerOffset + 4]) << 8) + Int64(data[headerOffset + 5])
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
        var h: ?UdpHandler = None
        for (handler in handlers) {
            if (handler.canHandle(packet)) {
                h = handler
                break
            }
        }
        match (h) {
            case Some(handler) => handler.handle(packet)
            case _ => packet.release()
        }
    }

    public func send(fromIP: Array<UInt8>, fromPort: UInt16, toIP: Array<UInt8>, toPort: UInt16, payload: Array<UInt8>) {
        let packet = pool.getPacket()
        packet.resetIPHeader()
        packet.setProtocol(protocol())
        packet.setSourceIP(fromIP)
        packet.setUdpSourcePort(fromPort)
        packet.setDestinationIP(toIP)
        packet.setUdpDestinationPort(toPort)
        packet.setUdpLength(packet.udpHeaderLength() + payload.size)
        let packetLength = packet.headerLength() + packet.udpHeaderLength() + payload.size
        packet.setLength(packetLength)
        packet.setUdpPayload(payload)
        packet.resumIPHeader()
        packet.resumUdp()
        this.device.write(packet.data.slice(0, packetLength))
        packet.release()
    }
}

public class UdpDirectHandler <: UdpHandler {
    let udpStack: UdpStack

    public init(stack: UdpStack) {
        udpStack = stack
    }

    public func canHandle(packet: IPPacket): Bool {
        true
    }

    public func handle(packet: IPPacket): Unit {
        spawn {
            redirectUdp(packet)
        }
        return
    }

    func redirectUdp(packet: IPPacket) {
        try {
            let udp = UdpSocket(bindAt: 0)
            udp.sendTimeout = Duration.second * 30
            udp.bind()
            udp.connect(SocketAddress(SocketAddressKind.IPv4, packet.destinationIP(), packet.udpDestinationPort()))
            let payload = packet.udpPayload()
            udp.send(payload)
            let buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
            let dataSize = udp.receive(buffer)
            if (dataSize <= buffer.size) {
                udpStack.send(packet.destinationIP(), packet.udpDestinationPort(), packet.sourceIP(),
                    packet.udpSourcePort(), buffer.slice(0, dataSize))
            }
        } catch (e: Exception) {
            Hilog.debug(0, "debugTun", "UDP Exception: ${e}")
        } finally {
            packet.release()
        }
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
        packet.udpDestinationPort() == 53
    }

    public func handle(packet: IPPacket): Unit {
        spawn {
            redirectDNSQuery(packet)
        }
        return
    }

    func getRequestDomains(packet: IPPacket): Array<String> {
        let domains = ArrayList<String>()
        var offset = packet.headerLength() + packet.udpHeaderLength() + packet.dnsHeaderLength()
        for (record in 0..packet.dnsQuestionCount()) {
            var domain = ""
            while (packet.data[offset] != 0) {
                for (i in 0..packet.data[offset]) {
                    domain += "${Rune(packet.data[offset + 1 + Int64(i)])}"
                }
                domain += "."
                offset += Int64(packet.data[offset]) + 1
            }
            domains.append(domain)
        }
        return domains.toArray()
    }

    func redirectDNSQuery(packet: IPPacket) {
        try {
            let udp = UdpSocket(bindAt: 0)
            udp.sendTimeout = Duration.second * 30
            udp.bind()
            let payload = packet.udpPayload()
            udp.connect(SocketAddress(SocketAddressKind.IPv4, server, 53))
            udp.send(payload)
            let buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
            let dataSize = udp.receive(buffer)
            if (dataSize <= buffer.size) {
                udpStack.send(packet.destinationIP(), packet.udpDestinationPort(), packet.sourceIP(),
                    packet.udpSourcePort(), buffer.slice(0, dataSize))
            }
        } catch (e: Exception) {
            Hilog.debug(0, "debugTun", "DNS Exception: ${e}")
        } finally {
            packet.release()
        }
    }
}
