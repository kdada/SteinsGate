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
                    if (now - socket.closedTimestamp > tcpSessionTimeout) {
                        outdatedSockets.append(socket)
                    }
                }
                for (socket in outdatedSockets) {
                    let key = IPPair(socket.sourceIP, socket.sourcePort, socket.destinationIP, socket.destinationPort)
                    if (sockets.get(key).isSome()) {
                        sockets.remove(key)
                    }
                    Hilog.debug(0, "TcpStack",
                        "Close outdated tcp socket ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
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

        var socket = sockets.get(pair)
        if (socket.isNone()) {
            let socket = TunTcpSocket(this, sourceIP, sourcePort, destinationIP, destinationPort)
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
                let handler = h.getOrThrow()
                spawn {
                    establishConnection(socket, handler)
                }
            } else {
                packet.release()
            }
        } else {
            let socket = socket.getOrThrow()
            let payload = packet.tcpPayload()

            var seqLength = UInt32(payload.size)
            if (seqLength == 0) {
                seqLength = 1
            }

            if ((packet.tcpSequenceNumber() - socket.remoteSequenceNumber) == seqLength) {
                socket.remoteSequenceNumber = packet.tcpSequenceNumber()
            }
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
            if (payload.size > 0) {
                sendAck(socket)
                socket.enqueue(packet)
            } else {
                handleControlPacket(socket, packet)
            }
        }
        return
    }

    private func establishConnection(socket: TunTcpSocket, handler: TunSocketHandler) {
        while (true) {
            let p = socket.packets.dequeue(Duration.second * tcpSessionTimeout)
            if (p.isNone()) {
                resetConnection(socket)
                break
            }
            let packet = p.getOrThrow()
            let success = match (socket.state) {
                case Init => {
                    => if (packet.tcpFlagSYN()) {
                        socket.state = SynReceived
                        socket.remoteSequenceNumber = packet.tcpSequenceNumber()
                        socket.remoteWindow = packet.tcpWindow()
                        let random = Random(UInt64(socket.remoteSequenceNumber))
                        socket.localSequenceNumber = random.nextUInt32() / 2
                        socket.sentSequenceNumber = socket.localSequenceNumber
                        let ackPacket = createTcpPacket(socket)
                        ackPacket.setTcpFlagSYN(true)
                        ackPacket.setTcpFlagACK(true)
                        ackPacket.resumTcp()
                        this.device.write(ackPacket.data.slice(0, ackPacket.length()))
                        ackPacket.release()
                        true
                    } else {
                        false
                    }
                }
                case SynReceived => {
                    => if (packet.tcpFlagACK() && packet.tcpAcknowledgementNumber() == (socket.localSequenceNumber + 1)) {
                        socket.state = Established
                        socket.remoteSequenceNumber = packet.tcpSequenceNumber()
                        socket.remoteWindow = packet.tcpWindow()
                        socket.sentSequenceNumber = packet.tcpAcknowledgementNumber()
                        handler.handle(socket)
                        true
                    } else {
                        false
                    }
                }
                case _ => {=> false}
            }()
            packet.release()
            if (!success) {
                resetConnection(socket)
                break
            }
        }
    }

    @OverflowWrapping
    private func handleControlPacket(socket: TunTcpSocket, packet: IPPacket) {
        if (packet.tcpFlagFIN() || packet.tcpFlagACK()) {
            match (socket.state) {
                case Establish => {
                    => if (packet.tcpFlagFIN()) {
                        socket.state = CloseWait
                        sendAck(socket)
                    }
                }
                case LastAck => {
                    => if (packet.tcpFlagACK()) {
                        if ((socket.sentSequenceNumber - socket.localSequenceNumber) == 1) {
                            socket.state = Closed
                        }
                    }
                }
                case FinWait1 => {
                    =>
                    if (packet.tcpFlagACK()) {
                        if ((socket.sentSequenceNumber - socket.localSequenceNumber) == 1) {
                            socket.state = FinWait2
                        }
                    }
                    if (packet.tcpFlagFIN()) {
                        socket.state = TimeWait
                        sendAck(socket)
                    }
                }
                case FinWait2 => {
                    => if (packet.tcpFlagFIN()) {
                        socket.state = TimeWait
                        sendAck(socket)
                    }
                }
                case _ => {=>}
            }()
            packet.release()
            return
        }
        packet.release()
        resetConnection(socket)
        return
    }

    private func sendAck(socket: TunTcpSocket) {
        sendSync(
            (socket as TunTcpSocket).getOrThrow(),
            packetModifier: {
                packet =>
                packet.setTcpFlagACK(true)
                packet.resumTcp()
            }
        )
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
        packet.setTcpAcknowledgementNumber(socket.remoteSequenceNumber + 1)
        packet.setTcpWindow(socket.remainingWindowSize())
        if (payload.size > 0) {
            socket.localSequenceNumber += UInt32(payload.size)
            packet.setTcpPayload(payload)
        } else {
            socket.localSequenceNumber++
        }
        packet.setTcpSequenceNumber(socket.localSequenceNumber)
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
        match (tcpSocket.state) {
            case Establish => {
                =>
                tcpSocket.state = FinWait1
                sendSync(
                    (socket as TunTcpSocket).getOrThrow(),
                    packetModifier: {
                        packet =>
                        packet.setTcpFlagFIN(true)
                        packet.resumTcp()
                    }
                )
            }
            case CloseWait => {
                =>
                tcpSocket.state = LastAck
                sendSync(
                    (socket as TunTcpSocket).getOrThrow(),
                    packetModifier: {
                        packet =>
                        packet.setTcpFlagFIN(true)
                        packet.resumTcp()
                    }
                )
            }
            case _ => {=> 0}
        }()
        return
    }
}

public class TcpDirectHandler <: TunSocketHandler {
    public func canHandle(socket: TunSocket): Bool {
        true
    }

    public func handle(socket: TunSocket): Unit {
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
                    var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
                    while (!socket.isClosed() && !tcp.isClosed()) {
                        let dataSize = tcp.read(buffer)
                        //Hilog.debug(0, "UdpDirectHandler",
                        //    "Receive udp data ${dataSize} ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                        //)
                        if (dataSize < 0) {
                            break
                        }
                        if (dataSize == 0 || dataSize > buffer.size) {
                            continue
                        }
                        socket.write(buffer.slice(0, dataSize))
                    }
                } catch (e: Exception) {
                    Hilog.error(0, "TcpDirectHandler",
                        "Receive ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
                } finally {
                    Hilog.debug(0, "TcpDirectHandler",
                        "TCP Receive Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                    socket.close()
                }
            }

            var buffer = Array<UInt8>(IPPacketMaxSize, item: 0)
            while (!socket.isClosed() && !tcp.isClosed()) {
                let count = socket.read(buffer)
                if (count < 0) {
                    break
                }
                if (count == 0) {
                    continue
                }
                //Hilog.debug(0, "UdpDirectHandler",
                //    "Read udp req ${count} ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                //)
                tcp.write(buffer.slice(0, count))
            }
        } catch (e: Exception) {
            Hilog.error(0, "TcpDirectHandler", "Send ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
        } finally {
            Hilog.debug(0, "TcpDirectHandler",
                "TCP Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            socket.close()
            tcp.close()
        }
    }
}
