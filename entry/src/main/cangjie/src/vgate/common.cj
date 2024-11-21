/**
 * Created on 2024/11/13
 */
package ohos_app_cangjie_entry.vgate

import std.collection.concurrent.NonBlockingQueue
import std.sync.AtomicInt64
import std.sync.sleep
import std.time.Duration

const IPPacketMaxSize = 1500
public const ProtocolTcp: UInt8 = 0x6
public const ProtocolUdp: UInt8 = 0x11

func exceptionToString(e: Exception): String {
    var message = " Exception: ${e.message}\n"
    for (trace in e.getStackTrace()) {
        message += "  ${trace.fileName}:${trace.lineNumber} ${trace.declaringClass}.${trace.methodName}\n"
    }
    return message
}

public struct IPPair <: Hashable & Equatable<IPPair> {
    var sourceIP: UInt32 = 0
    var sourcePort: UInt16 = 0
    var destinationIP: UInt32 = 0
    var destinationPort: UInt16 = 0

    public init(fromIP: Array<UInt8>, fromPort: UInt16, toIP: Array<UInt8>, toPort: UInt16) {
        sourceIP = (UInt32(fromIP[0]) << 24) + (UInt32(fromIP[1]) << 16) + (UInt32(fromIP[2]) << 8) + UInt32(fromIP[3])
        sourcePort = fromPort
        destinationIP = (UInt32(toIP[0]) << 24) + (UInt32(toIP[1]) << 16) + (UInt32(toIP[2]) << 8) + UInt32(toIP[3])
        destinationPort = toPort
    }

    @OverflowWrapping
    public func hashCode(): Int64 {
        ((Int64(sourceIP) * 31 + Int64(sourcePort)) * 31 + Int64(destinationIP)) * 31 + Int64(destinationPort)
    }

    public operator func ==(rhs: IPPair): Bool {
        sourceIP == rhs.sourceIP && sourcePort == rhs.sourcePort && destinationIP == rhs.destinationIP &&
            destinationPort == rhs.destinationPort
    }

    public operator func !=(rhs: IPPair): Bool {
        !(this == rhs)
    }
}

public class IPPacket {
    private let pool: IPPacketPool
    var data = Array<UInt8>(IPPacketMaxSize, item: 0)

    init(pool: IPPacketPool) {
        this.pool = pool
    }

    func isIPv4(): Bool {
        ((data[0] & 0xf0) >> 4) == 4
    }

    func headerLength(): Int64 {
        4 * Int64(data[0] & 0x0f)
    }

    func length(): Int64 {
        (Int64(data[2]) << 8) + Int64(data[3])
    }

    @OverflowWrapping
    func setLength(len: Int64) {
        data[2] = UInt8(len >> 8)
        data[3] = UInt8(len)
    }

    func payload(): Array<UInt8> {
        let headerLen = headerLength()
        data.slice(headerLen, length() - headerLen)
    }

    func protocol(): UInt8 {
        data[9]
    }

    func setProtocol(protocol: UInt8) {
        data[9] = protocol
    }

    func sourceIP(): Array<UInt8> {
        data.slice(12, 4).clone()
    }

    func sourceIPString(): String {
        let ip = data.slice(12, 4)
        "${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}"
    }

    func setSourceIP(newIP: Array<UInt8>) {
        newIP.copyTo(data, 0, 12, 4)
    }

    func destinationIP(): Array<UInt8> {
        data.slice(16, 4).clone()
    }

    func destinationIPString(): String {
        let ip = data.slice(16, 4)
        "${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}"
    }

    func setDestinationIP(newIP: Array<UInt8>) {
        newIP.copyTo(data, 0, 16, 4)
    }

    func validateIPHeader(): Bool {
        sum(data.slice(0, headerLength())) == 0
    }

    func resetIPHeader() {
        for (i in 0..20) {
            data[i] = 0
        }
        data[0] = 0x45
        data[3] = 20
        data[6] = 0x40
        data[8] = 255
    }

    @OverflowWrapping
    func resumIPHeader() {
        data[10] = 0
        data[11] = 0
        let result = sum(data.slice(0, headerLength()))
        data[10] = UInt8(result >> 8)
        data[11] = UInt8(result)
    }

    @OverflowWrapping
    func sum(data: Array<UInt8>): UInt16 {
        var result: UInt32 = 0
        for (i in 0..data.size - 1 : 2) {
            result += (UInt32(data[i]) << 8) + UInt32(data[i + 1])
        }
        if (data.size % 2 == 1) {
            result += UInt32(data[data.size - 1]) << 8
        }
        while ((result & 0xffff0000) != 0) {
            result = (result >> 16) + (result & 0x0000ffff)
        }
        return !UInt16(result)
    }

    @OverflowWrapping
    func sumWithPseudoIPHeader(payload: Array<UInt8>): UInt16 {
        let pseudoHeader = Array<UInt8>(12, item: 0)
        data.copyTo(pseudoHeader, 12, 0, 4)
        data.copyTo(pseudoHeader, 16, 4, 4)
        pseudoHeader[9] = data[9]
        pseudoHeader[10] = UInt8(payload.size >> 8)
        pseudoHeader[11] = UInt8(payload.size)
        let pseudoHeaderSum = sum(pseudoHeader)
        let dataSum = sum(payload)
        var result = UInt32(!pseudoHeaderSum) + UInt32(!dataSum)
        while ((result & 0xffff0000) != 0) {
            result = (result >> 16) + (result & 0x0000ffff)
        }
        return !UInt16(result)
    }

    func release() {
        this.pool.reuse(this)
    }
}

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

public class IPPacketPool {
    let packets: NonBlockingQueue<IPPacket>
    var closed = false
    let counter = AtomicInt64(0)

    public init(capacity: Int64) {
        this.packets = NonBlockingQueue<IPPacket>()
        spawn {gc()}
    }

    func reuse(packet: IPPacket) {
        if (!closed) {
            this.packets.enqueue(packet)
        }
    }

    func getPacket(): IPPacket {
        if (closed) {
            throw Exception("IPPacketPool is already closed")
        }
        if (let Some(packet) <- this.packets.dequeue()) {
            return packet
        }
        counter.fetchAdd(1)
        IPPacket(this)
    }

    func gc() {
        var lastCapacity = 0
        while (!closed) {
            sleep(Duration.second * 10)

            if (counter.swap(0) > 0) {
                continue
            }
            var gcCount = packets.size / 2
            while (gcCount > 0) {
                this.packets.dequeue()
                gcCount--
            }
        }
    }

    func close() {
        if (!closed) {
            closed = true
        }
    }
}
