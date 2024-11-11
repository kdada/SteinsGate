/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import ohos.hilog.Hilog
import std.collection.ArrayList
import std.collection.concurrent.ConcurrentHashMap
import std.sync.sleep
import std.time.DateTime
import std.time.Duration
import std.socket.*
import std.random.Random

extend IPPacket {
    func resetTcpHeader() {
        let headerOffset = headerLength()
        for (i in headerOffset..headerOffset + 20) {
            data[i] = 0
        }
        data[headerOffset + 12] = 0x50
    }

    func tcpSourcePort(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset]) << 8) + UInt16(data[headerOffset + 1])
    }

    @OverflowWrapping
    func setTcpSourcePort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset] = UInt8(port >> 8)
        data[headerOffset + 1] = UInt8(port)
    }

    func tcpDestinationPort(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset + 2]) << 8) + UInt16(data[headerOffset + 3])
    }

    @OverflowWrapping
    func setTcpDestinationPort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset + 2] = UInt8(port >> 8)
        data[headerOffset + 3] = UInt8(port)
    }

    func tcpSequenceNumber(): UInt32 {
        let headerOffset = headerLength()
        return (UInt32(data[headerOffset + 4]) << 24) + (UInt32(data[headerOffset + 5]) << 16) + (UInt32(data[headerOffset +
                6]) << 8) + UInt32(data[headerOffset + 7])
    }

    @OverflowWrapping
    func setTcpSequenceNumber(num: UInt32) {
        let headerOffset = headerLength()
        data[headerOffset + 4] = UInt8(num >> 24)
        data[headerOffset + 5] = UInt8(num >> 16)
        data[headerOffset + 6] = UInt8(num >> 8)
        data[headerOffset + 7] = UInt8(num)
    }

    func tcpAcknowledgementNumber(): UInt32 {
        let headerOffset = headerLength()
        return (UInt32(data[headerOffset + 8]) << 24) + (UInt32(data[headerOffset + 9]) << 16) + (UInt32(data[headerOffset +
                10]) << 8) + UInt32(data[headerOffset + 11])
    }

    @OverflowWrapping
    func setTcpAcknowledgementNumber(num: UInt32) {
        let headerOffset = headerLength()
        data[headerOffset + 8] = UInt8(num >> 24)
        data[headerOffset + 9] = UInt8(num >> 16)
        data[headerOffset + 10] = UInt8(num >> 8)
        data[headerOffset + 11] = UInt8(num)
    }

    func tcpHeaderLength(): Int64 {
        let headerOffset = headerLength()
        4 * Int64((data[headerOffset + 12] & 0xf0) >> 4)
    }

    func tcpFlagACK(): Bool {
        let headerOffset = headerLength()
        return (data[headerOffset + 13] & 0x10) != 0
    }

    func setTcpFlagACK(value: Bool) {
        let headerOffset = headerLength()
        if (value) {
            data[headerOffset + 13] |= 0x10
        } else {
            data[headerOffset + 13] &= !0x10
        }
    }

    func tcpFlagRST(): Bool {
        let headerOffset = headerLength()
        return (data[headerOffset + 13] & 0x04) != 0
    }

    func setTcpFlagRST(value: Bool) {
        let headerOffset = headerLength()
        if (value) {
            data[headerOffset + 13] |= 0x04
        } else {
            data[headerOffset + 13] &= !0x04
        }
    }

    func tcpFlagSYN(): Bool {
        let headerOffset = headerLength()
        return (data[headerOffset + 13] & 0x02) != 0
    }

    func setTcpFlagSYN(value: Bool) {
        let headerOffset = headerLength()
        if (value) {
            data[headerOffset + 13] |= 0x02
        } else {
            data[headerOffset + 13] &= !0x02
        }
    }

    func tcpFlagFIN(): Bool {
        let headerOffset = headerLength()
        return (data[headerOffset + 13] & 0x01) != 0
    }

    func setTcpFlagFIN(value: Bool) {
        let headerOffset = headerLength()
        if (value) {
            data[headerOffset + 13] |= 0x01
        } else {
            data[headerOffset + 13] &= !0x01
        }
    }

    func tcpWindow(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset + 14]) << 8) + UInt16(data[headerOffset + 15])
    }

    @OverflowWrapping
    func setTcpWindow(window: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset + 14] = UInt8(window >> 8)
        data[headerOffset + 15] = UInt8(window)
    }

    func tcpLength(): Int64 {
        length() - headerLength()
    }

    func tcpPayload(): Array<UInt8> {
        let headerLen = headerLength() + tcpHeaderLength()
        data.slice(headerLen, length() - headerLen)
    }

    func setTcpPayload(payload: Array<UInt8>) {
        payload.copyTo(data, 0, headerLength() + tcpHeaderLength(), payload.size)
    }

    @OverflowWrapping
    func resumTcp() {
        let headerOffset = headerLength()
        data[headerOffset + 16] = 0
        data[headerOffset + 17] = 0
        let result = sumWithPseudoIPHeader(payload())
        data[headerOffset + 16] = UInt8(result >> 8)
        data[headerOffset + 17] = UInt8(result)
    }

    func validateTcp(): Bool {
        sumWithPseudoIPHeader(payload()) == 0
    }
}

const tcpSessionTimeout = 30
const tcpMaxPayloadSize = 1400

public class TcpStack <: IPProtocolStack & TunSocketManager {
    let handlers = ArrayList<TunSocketHandler>()
    let device: TunDevice
    let pool: IPPacketPool
    let sockets = ConcurrentHashMap<IPPair, TunTcpSocket>()

    public init(device: TunDevice, pool: IPPacketPool) {
        this.device = device
        this.pool = pool
        spawn {
            while (device.running) {
                sleep(Duration.second * tcpSessionTimeout / 3)
                let outdatedSockets = ArrayList<TunTcpSocket>()
                let now = DateTime.now().toUnixTimeStamp().toSeconds()
                for ((_, socket) in sockets) {
                    if (socket.isClosed()) {
                        outdatedSockets.append(socket)
                    }
                }
                for (socket in outdatedSockets) {
                    let key = IPPair(socket.sourceIP, socket.sourcePort, socket.destinationIP, socket.destinationPort)
                    if (sockets.get(key).isSome()) {
                        sockets.remove(key)
                    }
                    //Hilog.debug(0, "TcpStack",
                    //    "Close outdated tcp socket ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)
                }
            }
        }
    }

    public func register(handler: TunSocketHandler) {
        handlers.append(handler)
    }

    public override func protocol(): UInt8 {
        return 0x6
    }

    @OverflowWrapping
    public override func pop(packet: IPPacket) {
        let sourceIP = packet.sourceIP()
        let sourcePort = packet.udpSourcePort()
        let destinationIP = packet.destinationIP()
        let destinationPort = packet.udpDestinationPort()
        let pair = IPPair(sourceIP, sourcePort, destinationIP, destinationPort)
        //Hilog.debug(0, "TcpDirectHandler",
        //    "TCP recv packet ${sourceIP}:${sourcePort} -> ${destinationIP}:${destinationPort}" +
        //    " length: ${packet.length()} payload: ${packet.length() - packet.headerLength() - packet.tcpHeaderLength()}" +
        //    " seq: ${packet.tcpSequenceNumber()} ack: ${packet.tcpAcknowledgementNumber()} window: ${packet.tcpWindow()}" +
        //    " flag(ACK<RST<SYN<FIN): ${packet.tcpFlagACK()} ${packet.tcpFlagRST()} ${packet.tcpFlagSYN()} ${packet.tcpFlagFIN()}"
        //)
        var socket = sockets.get(pair)
        if (socket.isNone()) {
            let socket = TunTcpSocket(this, sourceIP, sourcePort, destinationIP, destinationPort)
            var h: ?TunSocketHandler = None
            for (handler in handlers) {
                if (handler.canAccept(socket)) {
                    h = handler
                    break
                }
            }
            if (h.isSome()) {
                socket.enqueue(packet)
                sockets.put(pair, socket)
                let handler = h.getOrThrow()
                spawn {
                    try {
                        establishConnection(socket, handler)
                    } catch (e: Exception) {
                        Hilog.error(0, "TcpStack", exceptionToString(e))
                    }
                }
            } else {
                packet.release()
            }
        } else {
            let socket = socket.getOrThrow()
            let payload = packet.tcpPayload()
            if (packet.tcpSequenceNumber() == socket.remoteSequenceNumber) {
                if (packet.tcpFlagACK()) {
                    let min = UInt64(socket.sentSequenceNumber)
                    var max = UInt64(socket.localSequenceNumber) + 1
                    if (max < min) {
                        max += UInt64(2 ** 32)
                    }
                    var ack = UInt64(packet.tcpAcknowledgementNumber())
                    var ack2 = ack + UInt64(2 ** 32)
                    if ((ack > min && ack <= max) || (ack2 > min && ack2 <= max)) {
                        socket.sentSequenceNumber = packet.tcpAcknowledgementNumber()
                        socket.remoteWindow = packet.tcpWindow()
                    }
                }

                if (socket.state < Established) {
                    socket.enqueue(packet)
                } else if (payload.size > 0 && socket.state == Established) {
                    if (socket.enqueue(packet)) {
                        socket.remoteSequenceNumber += UInt32(payload.size)
                        sendSync(
                            socket,
                            packetModifier: {
                                packet =>
                                packet.setTcpFlagACK(true)
                                packet.resumTcp()
                            }
                        )
                    } else {
                        packet.release()
                    }
                } else {
                    handleControlPacket(socket, packet)
                }
            }
        }
        return
    }

    private func establishConnection(socket: TunTcpSocket, handler: TunSocketHandler) {
        //Hilog.debug(0, "TcpDirectHandler",
        //    "TCP start connection ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
        //)
        while (socket.state < Established) {
            let p = socket.packets.dequeue(Duration.second * tcpSessionTimeout)
            if (p.isNone()) {
                resetConnection(socket)
                break
            }
            let packet = p.getOrThrow()
            var success = false
            if (socket.state == SocketInit) {
                if (packet.tcpFlagSYN()) {
                    socket.state = SynReceived
                    socket.remoteSequenceNumber = packet.tcpSequenceNumber() + 1
                    socket.remoteWindow = packet.tcpWindow()
                    let random = Random(UInt64(socket.remoteSequenceNumber))
                    socket.localSequenceNumber = random.nextUInt32() / 2
                    socket.sentSequenceNumber = socket.localSequenceNumber
                    sendSync(
                        socket,
                        packetModifier: {
                            packet =>
                            packet.setTcpFlagSYN(true)
                            packet.setTcpFlagACK(true)
                            packet.resumTcp()
                        }
                    )
                    //Hilog.debug(0, "TcpDirectHandler",
                    //    "TCP SocketInit -> SynReceived ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)
                    packet.release()
                    success = true
                }
            } else if (socket.state == SynReceived) {
                if (packet.tcpFlagACK() && packet.tcpAcknowledgementNumber() == socket.localSequenceNumber + 1) {
                    socket.state = Established
                    socket.remoteSequenceNumber = packet.tcpSequenceNumber()
                    socket.remoteWindow = packet.tcpWindow()
                    socket.localSequenceNumber++
                    socket.sentSequenceNumber = packet.tcpAcknowledgementNumber()
                    //Hilog.debug(0, "TcpDirectHandler",
                    //    "TCP SynReceived -> Established ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)

                    if ((packet.length() - packet.headerLength() - packet.tcpHeaderLength()) > 0) {
                        socket.lastReadPacket = packet
                        socket.lastReadBytes = 0
                    } else {
                        packet.release()
                    }
                    handler.accept(socket)
                    success = true
                }
            }
            if (!success) {
                //Hilog.debug(0, "TcpDirectHandler",
                //    "TCP reset ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                //)
                packet.release()
                resetConnection(socket)
                break
            }
        }
    }

    @OverflowWrapping
    private func handleControlPacket(socket: TunTcpSocket, packet: IPPacket) {
        if (packet.tcpFlagFIN() || packet.tcpFlagACK()) {
            var payloadSize = packet.length() - packet.headerLength() - packet.tcpHeaderLength()
            if (payloadSize <= 0) {
                payloadSize = 1
            }
            if (socket.state == Established) {
                if (packet.tcpFlagFIN()) {
                    socket.state = CloseWait
                    socket.remoteSequenceNumber += UInt32(payloadSize)
                    sendSync(
                        socket,
                        packetModifier: {
                            packet =>
                            packet.setTcpFlagACK(true)
                            packet.resumTcp()
                        }
                    )
                    socket.readClosed = true
                    //Hilog.debug(0, "TcpDirectHandler",
                    //    "TCP Establish -> CloseWait ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)
                }
            } else if (socket.state == LastAck) {
                if (packet.tcpFlagACK()) {
                    if ((socket.sentSequenceNumber - socket.localSequenceNumber) == 1) {
                        socket.state = Closed
                    }
                    //Hilog.debug(0, "TcpDirectHandler",
                    //    "TCP LastAck -> Closed ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)
                }
            } else if (socket.state == FinWait1) {
                if (packet.tcpFlagACK()) {
                    if ((socket.sentSequenceNumber - socket.localSequenceNumber) == 1) {
                        socket.state = FinWait2
                    }
                    //Hilog.debug(0, "TcpDirectHandler",
                    //    "TCP FinWait1 -> FinWait2 ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)
                }
                if (packet.tcpFlagFIN()) {
                    socket.state = TimeWait
                    socket.remoteSequenceNumber += UInt32(payloadSize)
                    sendSync(
                        socket,
                        packetModifier: {
                            packet =>
                            packet.setTcpFlagACK(true)
                            packet.resumTcp()
                        }
                    )
                    socket.readClosed = true
                    //Hilog.debug(0, "TcpDirectHandler",
                    //    "TCP FinWait1 -> TimeWait ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)
                }
            } else if (socket.state == FinWait2) {
                if (packet.tcpFlagFIN()) {
                    socket.state = TimeWait
                    socket.remoteSequenceNumber += UInt32(payloadSize)
                    sendSync(
                        socket,
                        packetModifier: {
                            packet =>
                            packet.setTcpFlagACK(true)
                            packet.resumTcp()
                        }
                    )
                    socket.readClosed = true
                    //Hilog.debug(0, "TcpDirectHandler",
                    //    "TCP FinWait2 -> TimeWait ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    //)
                }
            }
            if (payloadSize > 0) {
                socket.enqueue(packet)
            } else {
                packet.release()
            }
            return
        }
        packet.release()
        resetConnection(socket)
        return
    }

    @OverflowWrapping
    private func createTcpPacket(socket: TunTcpSocket, payload!: Array<UInt8> = Array<UInt8>()) {
        let packet = pool.getPacket()
        packet.resetIPHeader()
        packet.resetTcpHeader()
        packet.setProtocol(protocol())
        packet.setSourceIP(socket.destinationIP)
        packet.setTcpSourcePort(socket.destinationPort)
        packet.setDestinationIP(socket.sourceIP)
        packet.setTcpDestinationPort(socket.sourcePort)
        packet.setTcpAcknowledgementNumber(socket.remoteSequenceNumber)
        packet.setTcpWindow(socket.remainingWindowSize())
        packet.setTcpSequenceNumber(socket.localSequenceNumber)
        if (payload.size > 0) {
            socket.localSequenceNumber += UInt32(payload.size)
            packet.setTcpPayload(payload)
        }
        let packetLength = packet.headerLength() + packet.tcpHeaderLength() + payload.size
        packet.setLength(packetLength)
        packet.resumIPHeader()
        return packet
    }

    private func resetConnection(socket: TunTcpSocket) {
        socket.state = Closed
        socket.close()
        let key = IPPair(socket.sourceIP, socket.sourcePort, socket.destinationIP, socket.destinationPort)
        if (sockets.get(key).isSome()) {
            sockets.remove(key)
        }
        sendSync(
            (socket as TunTcpSocket).getOrThrow(),
            packetModifier: {
                packet =>
                packet.setTcpFlagRST(true)
                packet.resumTcp()
            }
        )
    }

    private func sendSync(socket: TunTcpSocket, payload!: Array<UInt8> = Array<UInt8>(),
        packetModifier!: (IPPacket) -> Unit = {p =>}) {
        synchronized(socket.mutex) {
            let packet = createTcpPacket(socket, payload: payload)
            packetModifier(packet)
            let count = this.device.write(packet.data.slice(0, packet.length()))
            packet.release()
            //Hilog.debug(0, "TcpDirectHandler",
            //    "TCP send packet ${socket.destinationIP}:${socket.destinationPort} -> ${socket.sourceIP}:${socket.sourcePort}" +
            //    " state: ${socket.state} localseq: ${socket.localSequenceNumber}" +
            //    " length: ${packet.length()} payload: ${packet.length() - packet.headerLength() - packet.tcpHeaderLength()}" +
            //    " seq: ${packet.tcpSequenceNumber()} ack: ${packet.tcpAcknowledgementNumber()} window: ${packet.tcpWindow()}" +
            //    " flag(ACK<RST<SYN<FIN): ${packet.tcpFlagACK()} ${packet.tcpFlagRST()} ${packet.tcpFlagSYN()} ${packet.tcpFlagFIN()}"
            //)
            return count
        }
    }

    public func send(socket: TunSocket, payload: Array<UInt8>): Int64 {
        return sendSync(
            (socket as TunTcpSocket).getOrThrow(),
            payload: payload,
            packetModifier: {
                packet =>
                packet.setTcpFlagACK(true)
                packet.resumTcp()
            }
        )
    }

    public func close(socket: TunSocket) {
        let tcpSocket = (socket as TunTcpSocket).getOrThrow()
        if (tcpSocket.state == Established) {
            tcpSocket.state = FinWait1
            sendSync(
                (socket as TunTcpSocket).getOrThrow(),
                packetModifier: {
                    packet =>
                    packet.setTcpFlagFIN(true)
                    packet.resumTcp()
                }
            )
        //Hilog.debug(0, "TcpDirectHandler",
        //    "TCP Establish -> FinWait1 ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
        //)
        } else if (tcpSocket.state == CloseWait) {
            tcpSocket.state = LastAck
            sendSync(
                (socket as TunTcpSocket).getOrThrow(),
                packetModifier: {
                    packet =>
                    packet.setTcpFlagFIN(true)
                    packet.resumTcp()
                }
            )
            //Hilog.debug(0, "TcpDirectHandler",
            //    "TCP CloseWait -> LastAck ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            //)
        }
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
                    Hilog.error(0, "TcpDirectListener",
                        "Receive ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
                } finally {
                    Hilog.debug(0, "TcpDirectListener",
                        "TCP Receive Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                    socket.close()
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
            Hilog.error(0, "TcpDirectListener", "Send ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
        } finally {
            Hilog.debug(0, "TcpDirectListener",
                "TCP Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            tcp.close()
        }
    }
}
