/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import ohos.hilog.Hilog
import std.collection.*
import std.collection.concurrent.NonBlockingQueue
import std.socket.*
import std.time.Duration
import std.collection.concurrent.ConcurrentHashMap

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

public class UdpStack <: IPProtocolStack & TunSocketManager {
    let handlers = ArrayList<TunSocketHandler>()
    let device: TunDevice
    let pool: IPPacketPool
    let sockets = ConcurrentHashMap<IPPair, TunSocket>()

    public init(device: TunDevice, pool: IPPacketPool) {
        this.device = device
        this.pool = pool
    }

    public override func protocol(): UInt8 {
        return 0x11
    }

    public func register(handler: TunSocketHandler) {
        handlers.append(handler)
    }

    public override func pop(packet: IPPacket) {
        let sourceIP = packet.sourceIP()
        let sourcePort = packet.udpSourcePort()
        let destinationIP = packet.destinationIP()
        let destinationPort = packet.udpDestinationPort()
        let pair = IPPair(sourceIP, sourcePort, destinationIP, destinationPort)
        var socket = sockets.get(pair)
        if (socket.isNone()) {
            let socket = TunUdpSocket(this, sourceIP, sourcePort, destinationIP, destinationPort)
            var h: ?TunSocketHandler = None
            for (handler in handlers) {
                if (handler.canHandle(socket)) {
                    h = handler
                    break
                }
            }
            if (h.isSome()) {
                socket.enqueue(packet)
                sockets.put(pair, socket)
                h.getOrThrow().handle(socket)
            } else {
                packet.release()
            }
        } else {
            socket.getOrThrow().enqueue(packet)
        }
        return
    }

    private func send(fromIP: Array<UInt8>, fromPort: UInt16, toIP: Array<UInt8>, toPort: UInt16, payload: Array<UInt8>): Int64 {
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
        let count = this.device.write(packet.data.slice(0, packetLength))
        packet.release()
        return count
    }

    public func send(socket: TunSocket, payload: Array<UInt8>): Int64 {
        send(socket.destinationIP, socket.destinationPort, socket.sourceIP, socket.sourcePort, payload)
    }

    public func close(socket: TunSocket) {
        // TODO
        return
    }
}

public class UdpDirectHandler <: TunSocketHandler {
    public func canHandle(socket: TunSocket): Bool {
        true
    }

    public func handle(socket: TunSocket): Unit {
        spawn {
            redirectUdp(socket)
        }
        return
    }

    func redirectUdp(socket: TunSocket) {
        try {
            let udp = UdpSocket(bindAt: 0)
            udp.sendTimeout = Duration.second * 30
            udp.bind()
            udp.connect(SocketAddress(SocketAddressKind.IPv4, socket.destinationIP, socket.destinationPort))

            spawn {
                try {
                    var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
                    while (!socket.isClosed()) {
                        let dataSize = udp.receive(buffer)
                        if (dataSize <= buffer.size) {
                            socket.write(buffer.slice(0, dataSize))
                        }
                    }
                } catch (e: Exception) {
                    Hilog.debug(0, "debugTun", "UDP Receive Exception: ${e}")
                } finally {
                    Hilog.debug(0, "debugTun",
                        "UDP Receive Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                    socket.close()
                }
            }

            var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
            while (!socket.isClosed()) {
                let count = socket.read(buffer)
                if (count < 0) {
                    break
                }
                if (count == 0) {
                    continue
                }
                udp.send(buffer.slice(0, count))
            }
        } catch (e: Exception) {
            Hilog.debug(0, "debugTun", "UDP Send Exception: ${e}")
        } finally {
            Hilog.debug(0, "debugTun",
                "UDP Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            socket.close()
        }
    }
}

public class DnsHandler <: TunSocketHandler {
    let server: Array<UInt8>

    public init(ip: Array<UInt8>) {
        server = ip
    }

    public func canHandle(socket: TunSocket): Bool {
        socket.destinationPort == 53
    }

    public func handle(socket: TunSocket): Unit {
        spawn {
            redirectDNSQuery(socket)
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

    func redirectDNSQuery(socket: TunSocket) {
        try {
            let udp = UdpSocket(bindAt: 0)
            udp.sendTimeout = Duration.second * 30
            udp.bind()
            udp.connect(SocketAddress(SocketAddressKind.IPv4, server, 53))

            spawn {
                try {
                    var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
                    while (!socket.isClosed()) {
                        let dataSize = udp.receive(buffer)
                        if (dataSize <= buffer.size) {
                            socket.write(buffer.slice(0, dataSize))
                        }
                    }
                } catch (e: Exception) {
                    Hilog.debug(0, "debugTun", "DNS Receive Exception: ${e}")
                } finally {
                    Hilog.debug(0, "debugTun",
                        "DNS Receive Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                    socket.close()
                }
            }

            var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
            while (!socket.isClosed()) {
                let count = socket.read(buffer)
                if (count < 0) {
                    break
                }
                if (count == 0) {
                    continue
                }
                udp.send(buffer.slice(0, count))
            }
        } catch (e: Exception) {
            Hilog.debug(0, "debugTun", "DNS Send Exception: ${e}")
        } finally {
            Hilog.debug(0, "debugTun",
                "DNS Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            socket.close()
        }
    }
}
