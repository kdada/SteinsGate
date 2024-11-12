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
import std.sync.sleep
import std.time.DateTime

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

const udpSessionTimeout = 30

public class UdpStack <: IPProtocolStack & TunSocketManager {
    let handlers = ArrayList<TunSocketHandler>()
    let device: TunDevice
    let pool: IPPacketPool
    let sockets = ConcurrentHashMap<IPPair, TunSocket>()

    public init(device: TunDevice, pool: IPPacketPool) {
        this.device = device
        this.pool = pool
        spawn {
            while (device.running) {
                sleep(Duration.second * udpSessionTimeout / 3)
                let outdatedSockets = ArrayList<TunSocket>()
                let now = DateTime.now().toUnixTimeStamp().toSeconds()
                for ((_, socket) in sockets) {
                    if (now - socket.lastReceivedTimestamp > udpSessionTimeout && now - socket.lastSentTimestamp >
                        udpSessionTimeout) {
                        outdatedSockets.append(socket)
                    }
                }
                for (socket in outdatedSockets) {
                    socket.close()
                    Hilog.debug(0, "UdpStack",
                        "Close outdated udp socket ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                }
            }
        }
    }

    public override func protocol(): UInt8 {
        return ProtocolUdp
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
                if (handler.canAccept(socket, packet)) {
                    h = handler
                    break
                }
            }
            if (h.isSome()) {
                socket.enqueue(packet)
                sockets.put(pair, socket)
                h.getOrThrow().accept(socket)
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
        let key = IPPair(socket.sourceIP, socket.sourcePort, socket.destinationIP, socket.destinationPort)
        if (sockets.get(key).isSome()) {
            sockets.remove(key)
        }
        if (!socket.isClosed()) {
            socket.close()
        }
        return
    }
}

public class UdpDirectListener <: TunSocketListener {
    public func accept(socket: TunSocket): Unit {
        spawn {
            redirectUdp(socket)
        }
        return
    }

    func redirectUdp(socket: TunSocket) {
        let udp = UdpSocket(bindAt: 0)
        try {
            udp.sendTimeout = Duration.second * udpSessionTimeout
            udp.bind()
            udp.connect(SocketAddress(SocketAddressKind.IPv4, socket.destinationIP, socket.destinationPort))

            spawn {
                try {
                    var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
                    while (!socket.isClosed() && !udp.isClosed()) {
                        let dataSize = udp.receive(buffer)
                        if (dataSize < 0) {
                            break
                        }
                        if (dataSize == 0 || dataSize > buffer.size) {
                            continue
                        }
                        socket.write(buffer.slice(0, dataSize))
                    }
                } catch (e: Exception) {
                    Hilog.error(0, "UdpDirectListener",
                        "Receive ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
                } finally {
                    Hilog.debug(0, "UdpDirectListener",
                        "UDP Receive Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                    socket.close()
                }
            }

            var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
            while (!socket.isClosed() && !udp.isClosed()) {
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
            Hilog.error(0, "UdpDirectListener", "Send ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
        } finally {
            Hilog.debug(0, "UdpDirectListener",
                "UDP Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            socket.close()
            udp.close()
        }
    }
}

public class OnlyDNSRequest <: TunSocketChecker {
    public func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool {
        socket.destinationPort == 53
    }
}

public class DnsDirectListener <: TunSocketListener {
    let server: Array<UInt8>

    public init(ip: Array<UInt8>) {
        server = ip
    }

    public func canAccept(socket: TunSocket): Bool {
        socket.destinationPort == 53
    }

    public func accept(socket: TunSocket): Unit {
        spawn {
            redirectDNSQuery(socket)
        }
        return
    }

    func redirectDNSQuery(socket: TunSocket) {
        let udp = UdpSocket(bindAt: 0)
        try {
            udp.sendTimeout = Duration.second * udpSessionTimeout
            udp.bind()
            udp.connect(SocketAddress(SocketAddressKind.IPv4, server, 53))

            spawn {
                try {
                    var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
                    while (!socket.isClosed()) {
                        let dataSize = udp.receive(buffer)
                        if (dataSize < 0) {
                            break
                        }
                        if (dataSize == 0 || dataSize > buffer.size) {
                            continue
                        }
                        socket.write(buffer.slice(0, dataSize))
                    }
                } catch (e: Exception) {
                    Hilog.error(0, "DnsDirectListener",
                        "Receive ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
                } finally {
                    Hilog.debug(0, "DnsDirectListener",
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
            Hilog.error(0, "DnsDirectListener", "Send ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
        } finally {
            Hilog.debug(0, "DnsDirectListener",
                "DNS Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            socket.close()
            udp.close()
        }
    }
}
