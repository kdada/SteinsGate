/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.vgate

import std.collection.*
import std.collection.concurrent.*
import std.socket.*
import std.sync.*
import std.time.*
import ohos.hilog.*

const udpSessionTimeout = 30

public class UdpStack <: IPProtocolStack & TunSocketManager {
    let handlers = ArrayList<TunSocketHandler>()
    let device: TunDevice
    let pool: IPPacketPool
    let sockets = ConcurrentHashMap<IPPair, TunSocket>()
    var closed = false
    let packets: BlockingQueue<IPPacket>
    let routines = Array<?Future<Unit>>(2, item: None)

    public init(device: TunDevice, pool: IPPacketPool, packetCapacity!: Int64 = 1000) {
        this.device = device
        this.pool = pool
        this.packets = BlockingQueue<IPPacket>(packetCapacity)
        routines[0] = spawn {terminateOutdatedSockets()}
        routines[1] = spawn {handleLoop()}
    }

    func terminateOutdatedSockets() {
        let checkInterval = Duration.second * udpSessionTimeout / 3
        while (!closed) {
            var interval = Duration.Zero
            while (interval < checkInterval) {
                sleep(Duration.millisecond * 100)
                if (closed) {
                    break
                }
                interval += Duration.millisecond * 100
            }
            if (closed) {
                break
            }
            let outdatedSockets = ArrayList<TunSocket>()
            let now = DateTime.now().toUnixTimeStamp().toSeconds()
            for ((key, socket) in sockets) {
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

    func handleLoop() {
        while (!closed) {
            if (let Some(packet) <- packets.dequeue(Duration.millisecond * 100)) {
                pop(packet)
            }
        }
    }

    public func register(handler: TunSocketHandler) {
        handlers.append(handler)
    }

    public override func protocol(): UInt8 {
        return ProtocolUdp
    }

    public override func enqueue(packet: IPPacket) {
        packets.tryEnqueue(packet)
    }

    func pop(packet: IPPacket) {
        let sourceIP = packet.sourceIP()
        let sourcePort = packet.udpSourcePort()
        let destinationIP = packet.destinationIP()
        let destinationPort = packet.udpDestinationPort()
        let pair = IPPair(sourceIP, sourcePort, destinationIP, destinationPort)

        if (let Some(socket) <- sockets.get(pair)) {
            if (!socket.enqueue(packet)) {
                packet.release()
            }
        } else {
            let socket = TunUdpSocket(this, sourceIP, sourcePort, destinationIP, destinationPort)
            var h: ?TunSocketHandler = None
            for (handler in handlers) {
                if (handler.canAccept(socket, packet)) {
                    h = handler
                    break
                }
            }
            if (let Some(handler) <- h) {
                if (socket.enqueue(packet)) {
                    sockets.put(pair, socket)
                    handler.accept(socket)
                } else {
                    packet.release()
                }
            } else {
                packet.release()
            }
        }
        return
    }

    public func send(socket: TunSocket, payload: Array<UInt8>): Int64 {
        let packet = pool.getPacket()
        packet.resetIPHeader()
        packet.setProtocol(protocol())
        packet.setSourceIP(socket.destinationIP)
        packet.setUdpSourcePort(socket.destinationPort)
        packet.setDestinationIP(socket.sourceIP)
        packet.setUdpDestinationPort(socket.sourcePort)
        packet.setUdpLength(packet.udpHeaderLength() + payload.size)
        let packetLength = packet.headerLength() + packet.udpHeaderLength() + payload.size
        if (packetLength > IPPacketMaxSize) {
            packet.release()
            return -1
        }
        packet.setLength(packetLength)
        packet.setUdpPayload(payload)
        packet.resumIPHeader()
        packet.resumUdp()
        if (!this.device.enqueue(packet)) {
            packet.release()
            return -1
        }
        return payload.size
    }

    public func terminate(socket: TunSocket) {
        if (!socket.isClosed()) {
            socket.close()
        } else {
            let key = IPPair(socket.sourceIP, socket.sourcePort, socket.destinationIP, socket.destinationPort)
            if (sockets.get(key).isSome()) {
                sockets.remove(key)
            }
        }
        return
    }

    public func close() {
        if (closed) {
            return
        }
        closed = true
        for (routine in routines) {
            routine?.get()
        }
    }
}

public open class UdpDirectListener <: TunSocketListener {
    var logTag = "UdpDirectListener"

    public open func accept(socket: TunSocket): Unit {
        spawn {
            redirectUdp(socket)
        }
        return
    }

    protected open func connect(udp: UdpSocket, socket: TunSocket) {
        udp.connect(SocketAddress(SocketAddressKind.IPv4, socket.destinationIP, socket.destinationPort))
    }

    func redirectUdp(socket: TunSocket) {
        let udp = UdpSocket(bindAt: 0)
        try {
            udp.sendTimeout = Duration.second * udpSessionTimeout
            udp.bind()
            connect(udp, socket)

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
                    Hilog.error(0, logTag,
                        "${socket.destinationIP}:${socket.destinationPort} -> ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}"
                    )
                } finally {
                    socket.close()
                    Hilog.debug(0, logTag,
                        "UDP(In) Closed ${socket.destinationIP}:${socket.destinationPort} -> ${socket.sourceIP}:${socket.sourcePort}"
                    )
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
            Hilog.error(0, logTag, "Send ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
        } finally {
            udp.close()
            Hilog.debug(0, logTag,
                "UDP(Out) Closed ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
        }
    }
}

public class DnsDirectListener <: UdpDirectListener {
    let dnsServer: Array<UInt8>

    public init(ip: Array<UInt8>) {
        logTag = "DnsDirectListener"
        dnsServer = ip
    }

    protected override func connect(udp: UdpSocket, socket: TunSocket) {
        udp.connect(SocketAddress(SocketAddressKind.IPv4, dnsServer, 53))
    }
}
