/**
 * Created on 2024/11/7
 */
package ohos_app_cangjie_entry.tun

import std.collection.concurrent.BlockingQueue

const IPPacketMaxSize = 1500

public struct IPPair <: Hashable & Equatable<IPPair> {
    var sourceIP: UInt32 = 0
    var sourcePort: UInt16 = 0
    var destinationIP: UInt32 = 0
    var destinationPort: UInt16 = 0

    public init(fromIP: Array<UInt8>, fromPort: UInt16, toIP: Array<UInt8>, toPort: UInt16) {
        sourceIP = UInt32(fromIP[0]) << 24 + UInt32(fromIP[1]) << 16 + UInt32(fromIP[2]) << 8 + UInt32(fromIP[3])
        sourcePort = fromPort
        destinationIP = UInt32(toIP[0]) << 24 + UInt32(toIP[1]) << 16 + UInt32(toIP[2]) << 8 + UInt32(toIP[3])
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
        this.pool.packets.tryEnqueue(this)
        return
    }
}

public class IPPacketPool {
    let packets: BlockingQueue<IPPacket>

    public init(capacity: Int64) {
        this.packets = BlockingQueue<IPPacket>(capacity)
    }

    func getPacket(): IPPacket {
        match (this.packets.tryDequeue()) {
            case Some(p) => p
            case _ => IPPacket(this)
        }
    }
}
