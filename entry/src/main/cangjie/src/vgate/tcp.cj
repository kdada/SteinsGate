/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.vgate

import ohos.hilog.*
import std.collection.ArrayList
import std.collection.concurrent.*
import std.sync.*
import std.time.*
import std.socket.*
import std.random.*
import std.math.*

const tcpSessionTimeout = 30
const tcpMaxPayloadSize = 1400

public class TcpStack <: IPProtocolStack & TunSocketManager {
    let handlers = ArrayList<TunSocketHandler>()
    let device: TunDevice
    let pool: IPPacketPool
    let sockets = ConcurrentHashMap<IPPair, TunTcpSocket>()
    var closed = false
    let queues: Array<BlockingQueue<IPPacket>>
    let routines: Array<?Future<Unit>>
    var sender: ?Future<Unit> = None
    var terminater: ?Future<Unit> = None

    public init(device: TunDevice, pool: IPPacketPool, queueCount!: Int64 = 5, packetCapacity!: Int64 = 1000) {
        this.device = device
        this.pool = pool
        var count = queueCount
        if (count < 1) {
            count = 1
        }
        queues = Array<BlockingQueue<IPPacket>>(count, {_ => BlockingQueue<IPPacket>(packetCapacity)})
        routines = Array<?Future<Unit>>(count, item: None)
        for (index in 0..count) {
            let i = index
            routines[i] = spawn {handleLoop(queues[i])}
        }
        sender = spawn {sendLoop()}
        terminater = spawn {terminateOutdatedSockets()}
    }

    func terminateOutdatedSockets() {
        let checkInterval = Duration.second * tcpSessionTimeout / 3
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
            let outdatedSockets = ArrayList<TunTcpSocket>()
            let now = DateTime.now().toUnixTimeStamp().toSeconds()
            for ((key, socket) in sockets) {
                if (now - socket.lastReceivedTimestamp > tcpSessionTimeout && now - socket.lastSentTimestamp >
                    tcpSessionTimeout) {
                    outdatedSockets.append(socket)
                }
            }
            for (socket in outdatedSockets) {
                if (socket.state == Established) {
                    socket.close()
                } else {
                    let key = IPPair(socket.sourceIP, socket.sourcePort, socket.destinationIP, socket.destinationPort)
                    if (sockets.get(key).isSome()) {
                        sockets.remove(key)
                    }
                }
                Hilog.debug(0, "TcpStack",
                    "Close/Remove outdated tcp socket ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                )
            }
        }
    }

    func handleLoop(queue: BlockingQueue<IPPacket>) {
        while (!closed) {
            if (let Some(packet) <- queue.dequeue(Duration.millisecond * 100)) {
                try {
                    handle(packet)
                } catch (e: Exception) {
                    Hilog.error(0, "TcpStack", exceptionToString(e))
                }
            }
        }
    }

    func sendLoop() {
        var sent = false
        var start = DateTime.now().toUnixTimeStamp().toMilliseconds()
        while (!closed) {
            if (!sent) {
                sleep(Duration.millisecond * 10)
                sent = false
            }
            var current = DateTime.now().toUnixTimeStamp().toMilliseconds()
            let tick = current - start > 100
            if (tick) {
                start = current
            }
            for (queue in queues) {
                if (closed) {
                    break
                }
                for ((_, socket) in sockets) {
                    if (send(socket, tick)) {
                        sent = true
                    }
                }
            }
        }
    }

    public func register(handler: TunSocketHandler) {
        handlers.append(handler)
    }

    public override func protocol(): UInt8 {
        return ProtocolTcp
    }

    public override func enqueue(packet: IPPacket) {
        let index = IPPair(packet.sourceIP(), packet.tcpSourcePort(), packet.destinationIP(),
            packet.tcpDestinationPort()).hashCode() % queues.size
        queues[index].tryEnqueue(packet)
    }

    @OverflowWrapping
    func handle(packet: IPPacket) {
        try {
            let sourceIP = packet.sourceIP()
            let sourcePort = packet.udpSourcePort()
            let destinationIP = packet.destinationIP()
            let destinationPort = packet.udpDestinationPort()
            let pair = IPPair(sourceIP, sourcePort, destinationIP, destinationPort)
            var s = sockets.get(pair)
            if (s.isNone()) {
                if (!packet.tcpFlagSYN()) {
                    return
                }
                s = TunTcpSocket(this, sourceIP, sourcePort, destinationIP, destinationPort)
                sockets.put(pair, s.getOrThrow())
            }
            let socket = s.getOrThrow()

            if (packet.tcpFlagACK()) {
                socket.setRemoteWindowSize(packet.tcpWindow(), packet.tcpAcknowledgementNumber())
            }

            if (socket.state == SocketInit) {
                if (packet.tcpFlagSYN()) {
                    socket.state = SynReceived
                    socket.remoteNextSequenceNumber = packet.tcpSequenceNumber() + 1
                    socket.remoteWindowSize = packet.tcpWindow()
                    let random = Random(UInt64(socket.remoteNextSequenceNumber))
                    socket.localNextSequenceNumber = random.nextUInt32() / 2
                    socket.localAcknowledgementNumber = socket.localNextSequenceNumber
                    sendTcpPacket(
                        socket,
                        {
                            packet =>
                            packet.setTcpFlagSYN(true)
                            socket.localNextSequenceNumber++
                            0
                        }
                    )
                    return
                }
            } else if (socket.state == SynReceived) {
                if (packet.tcpFlagACK() && packet.tcpAcknowledgementNumber() == socket.localNextSequenceNumber) {
                    socket.state = Established
                    let payload = packet.tcpPayload()
                    if (payload.size > 0) {
                        socket.offloadPayload(payload)
                        if (!socket.accepted) {
                            for (handler in handlers) {
                                if (handler.canAccept(socket, packet)) {
                                    handler.accept(socket)
                                    socket.accepted = true
                                    break
                                }
                            }
                        }
                    }
                    return
                }
            } else if (socket.state == Established) {
                if (packet.tcpSequenceNumber() == socket.remoteNextSequenceNumber) {
                    let payload = packet.tcpPayload()
                    if (payload.size > 0) {
                        if (!socket.offloadPayload(payload)) {
                            return
                        }
                        if (!socket.accepted) {
                            for (handler in handlers) {
                                if (handler.canAccept(socket, packet)) {
                                    handler.accept(socket)
                                    socket.accepted = true
                                    break
                                }
                            }
                        }
                    }
                    if (packet.tcpFlagFIN()) {
                        socket.state = CloseWait
                        socket.remoteNextSequenceNumber++
                    }
                }
            } else if (socket.state == CloseWait) {
            } else if (socket.state == LastAck) {
                if (packet.tcpFlagACK()) {
                    if (socket.localNextSequenceNumber == socket.localAcknowledgementNumber) {
                        socket.state = Closed
                    }
                }
            } else if (socket.state == FinWait1 || socket.state == FinWait2) {
                if (packet.tcpSequenceNumber() == socket.remoteNextSequenceNumber) {
                    let payload = packet.tcpPayload()
                    if (payload.size > 0) {
                        if (!socket.offloadPayload(payload)) {
                            return
                        }
                    }

                    if (packet.tcpFlagACK()) {
                        if (socket.localNextSequenceNumber == socket.localAcknowledgementNumber) {
                            socket.state = FinWait2
                            if (packet.tcpFlagFIN()) {
                                socket.state = TimeWait
                                socket.remoteNextSequenceNumber++
                                sendTcpPacket(socket, {packet => 0})
                            }
                        }
                    }
                }
            } else if (socket.state == TimeWait || socket.state == Closed) {
            }
        } finally {
            packet.release()
        }
    }

    public func send(socket: TunTcpSocket, tick: Bool): Bool {
        var sent = false
        if (socket.state == Established || socket.state == CloseWait) {
            socket.writeMutex.lock()
            while (true) {
                let unreceivedDataSize = (Int64(socket.localNextSequenceNumber) + Int64(UInt32.Max) - Int64(socket.
                    localAcknowledgementNumber)) % Int64(UInt32.Max)
                let writableDataSize = socket.writableDataSize - unreceivedDataSize
                let remainingWindowSize = socket.getRemoteRemainingWindowSize()
                if (writableDataSize <= 0 || remainingWindowSize <= 0) {
                    break
                }
                sent = true
                let startIndex = (socket.startIndexOfWritableData + unreceivedDataSize) % Int64(UInt32.Max)
                let dataSizeToSend = min(writableDataSize, Int64(remainingWindowSize))

                socket.localNextSequenceNumber += UInt32(sendTcpPacket(
                    socket,
                    {
                        packet =>
                        let headerLength = packet.headerLength() + packet.tcpHeaderLength()
                        let payloadSize = min(packet.data.size - headerLength, dataSizeToSend)
                        let copiedSize = min(payloadSize, socket.writeBuffer.size - startIndex)

                        socket.writeBuffer.copyTo(packet.data, startIndex, headerLength, copiedSize)
                        if (copiedSize < payloadSize) {
                            socket.writeBuffer.copyTo(packet.data, 0, headerLength + copiedSize, payloadSize - copiedSize
                            )
                        }
                        payloadSize
                    }
                ))
            }

            if (socket.writableDataSize <= 0 && socket.closed) {
                if (socket.state == Established) {
                    socket.state = FinWait1
                    sent = true
                    sendTcpPacket(
                        socket,
                        {
                            packet =>
                            packet.setTcpFlagFIN(true)
                            socket.localNextSequenceNumber++
                            0
                        }
                    )
                } else if (socket.state == CloseWait) {
                    socket.state = LastAck
                    sent = true
                    sendTcpPacket(
                        socket,
                        {
                            packet =>
                            packet.setTcpFlagFIN(true)
                            socket.localNextSequenceNumber++
                            0
                        }
                    )
                }
            }
            socket.writeMutex.unlock()
        }
        if (tick && !sent) {
            if (socket.remoteNextSequenceNumber != socket.remoteAcknowledgementNumber) {
                sendTcpPacket(socket, {packet => 0})
            }
            if (socket.getRemoteRemainingWindowSize() <= 0) {
                sendTcpPacket(socket, {packet => 0})
            }
            if (socket.sentLocalWindowSize <= 0) {
                sendTcpPacket(socket, {packet => 0})
            }
        }
        return sent
    }

    @OverflowWrapping
    private func sendTcpPacket(socket: TunTcpSocket, modifier: (packet: IPPacket) -> Int64): Int64 {
        let packet = pool.getPacket()
        packet.resetIPHeader()
        packet.resetTcpHeader()
        packet.setProtocol(protocol())
        packet.setSourceIP(socket.destinationIP)
        packet.setTcpSourcePort(socket.destinationPort)
        packet.setDestinationIP(socket.sourceIP)
        packet.setTcpDestinationPort(socket.sourcePort)

        socket.writeMutex.lock()
        packet.setTcpAcknowledgementNumber(socket.remoteNextSequenceNumber)
        packet.setTcpFlagACK(true)
        packet.setTcpWindow(socket.getLocalRemainingWindowSize())
        packet.setTcpSequenceNumber(socket.localNextSequenceNumber)

        let payloadLength = modifier(packet)
        packet.setLength(packet.headerLength() + packet.tcpHeaderLength() + payloadLength)
        socket.localNextSequenceNumber += UInt32(payloadLength)

        if (packet.tcpFlagACK()) {
            let ackNumber = packet.tcpAcknowledgementNumber()
            if (ackNumber > socket.remoteAcknowledgementNumber) {
                socket.remoteAcknowledgementNumber = ackNumber
                socket.sentLocalWindowSize = packet.tcpWindow()
            }
        }

        packet.resumIPHeader()
        packet.resumTcp()
        device.enqueue(packet)
        socket.writeMutex.unlock()
        return payloadLength
    }

    public func send(socket: TunSocket, payload: Array<UInt8>): Int64 {
        throw Exception("Not Implement")
    }

    public func terminate(socket: TunSocket) {
        return
    }

    public func close() {
        closed = true
        sender?.get()
        for (handler in routines) {
            handler?.get()
        }
        terminater?.get()
        return
    }
}

public class TcpDirectListener <: TunSocketListener {
    public func accept(socket: TunSocket): Unit {
        spawn {
            redirectTcp(socket)
        }
        return
    }

    func redirectTcp(socket: TunSocket) {
        let tcp = TcpSocket(SocketAddress(SocketAddressKind.IPv4, socket.destinationIP, socket.destinationPort))
        let timeout = Duration.second * tcpSessionTimeout
        try {
            tcp.writeTimeout = timeout
            tcp.connect(timeout: timeout)

            spawn {
                try {
                    var buffer = Array<UInt8>(tcpMaxPayloadSize, item: 0)
                    while (!socket.isClosed() && !tcp.isClosed()) {
                        let dataSize = tcp.read(buffer)
                        if (dataSize < 0) {
                            break
                        }
                        if (dataSize == 0 || dataSize > buffer.size) {
                            continue
                        }
                        socket.write(buffer.slice(0, dataSize))
                    }
                } catch (e: Exception) {
                    if (!tcp.isClosed()) {
                        Hilog.error(0, "TcpDirectListener",
                            "Receive ${socket.destinationIP}:${socket.destinationPort} -> ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}"
                        )
                    }
                } finally {
                    socket.close()
                    Hilog.debug(0, "TcpDirectListener",
                        "TCP(In) Closed ${socket.destinationIP}:${socket.destinationPort} -> ${socket.sourceIP}:${socket.sourcePort}"
                    )
                }
            }

            var buffer = Array<UInt8>(tcpMaxPayloadSize, item: 0)
            while (!socket.isClosed() && !tcp.isClosed()) {
                let count = socket.read(buffer)
                if (count < 0) {
                    break
                }
                if (count == 0) {
                    continue
                }
                tcp.write(buffer.slice(0, count))
            }
        } catch (e: Exception) {
            Hilog.error(0, "TcpDirectListener",
                "Send ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort} ${exceptionToString(e)}"
            )
        } finally {
            Hilog.debug(0, "TcpDirectListener",
                "TCP(Out) Closed ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            tcp.close()
        }
    }
}
