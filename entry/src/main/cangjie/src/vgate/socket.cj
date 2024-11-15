/**
 * Created on 2024/11/7
 */
package ohos_app_cangjie_entry.vgate

import std.collection.concurrent.*
import std.math.*
import std.time.*
import std.sync.*
import std.convert.*
import std.collection.*
import ohos.hilog.*

public interface TunSocketManager {
    func send(socket: TunSocket, payload: Array<UInt8>): Int64
    func terminate(socket: TunSocket): Unit
}

public interface TunSocketChecker {
    func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool
}

public interface TunSocketListener {
    func accept(socket: TunSocket): Unit
}

public interface TunSocketHandler <: TunSocketChecker & TunSocketListener {}

public class CustomTunSocketHandler <: TunSocketHandler {
    public CustomTunSocketHandler(let checker: TunSocketChecker, let listener: TunSocketListener) {}

    public func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool {
        return checker.canAccept(socket, firstDataPacket)
    }
    public func accept(socket: TunSocket): Unit {
        return listener.accept(socket)
    }
}

public class All <: TunSocketChecker {
    public func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool {
        return true
    }
}

public class Not <: TunSocketChecker {
    Not(let checker: TunSocketChecker) {}

    public func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool {
        !checker.canAccept(socket, firstDataPacket)
    }
}

public class OnlyDNSRequest <: TunSocketChecker {
    public func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool {
        socket.destinationPort == 53
    }
}

struct IPMask {
    IPMask(let ip: UInt32, let mask: UInt32) {}
}

public class InAddresses <: TunSocketChecker {
    let ips = Array<ArrayList<IPMask>>(256, item: ArrayList<IPMask>())

    public init(addresses: String) {
        let addressArray = addresses.split("\n", removeEmpty: true)
        for (address in addressArray) {
            let ipmask = address.split("/", removeEmpty: true)
            if (ipmask.size != 2) {
                continue
            }
            let ipParts = ipmask[0].split(".", removeEmpty: true)
            if (ipParts.size != 4) {
                continue
            }

            let mask = UInt8.tryParse(ipmask[1])
            if (mask.isNone()) {
                continue
            }
            let m = mask.getOrThrow()
            if (m < 8 || m > 24) {
                continue
            }

            var ip: UInt32 = 0
            var parsed = true
            for (part in ipParts) {
                var p = UInt8.tryParse(part)
                if (p.isNone()) {
                    parsed = false
                    break
                }
                ip = (ip << 8) + UInt32(p.getOrThrow())
            }
            if (!parsed) {
                continue
            }
            var bmask = UInt32(0)
            for (_ in 0..m) {
                bmask = (bmask >> 1) | 0x80000000
            }
            ips[Int64(ip >> 24)].append(IPMask(ip, bmask))
        }
    }

    public func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool {
        let toIP = socket.destinationIP
        let destinationIP = (UInt32(toIP[0]) << 24) + (UInt32(toIP[1]) << 16) + (UInt32(toIP[2]) << 8) + UInt32(toIP[3])
        for (ipMask in ips[Int64(toIP[0])]) {
            if ((destinationIP & ipMask.mask) == ipMask.ip) {
                return true
            }
        }
        return false
    }
}

public class InDomains <: TunSocketChecker {
    let domains = HashMap<String, Any>()

    public init(domainList: String) {
        let domainArray = domainList.split("\n", removeEmpty: true)
        for (domain in domainArray) {
            let parts = domain.split(".", removeEmpty: true)
            var inMap = domains
            for (index in (parts.size - 1)..=0 : -1) {
                let result = inMap.get(parts[index])
                if (result.isNone()) {
                    let nextLevel = HashMap<String, Any>()
                    inMap.put(parts[index], nextLevel)
                    inMap = nextLevel
                } else {
                    inMap = (result.getOrThrow() as HashMap<String, Any>).getOrThrow()
                }
            }
            inMap.put("", true)
        }
    }

    func dnsQuestionCount(payload: Array<UInt8>): Int64 {
        return (Int64(payload[4]) << 8) + Int64(payload[5])
    }

    func getRequestDomains(payload: Array<UInt8>): Array<String> {
        let domains = ArrayList<String>()
        let count = dnsQuestionCount(payload)
        var offset = 12
        for (record in 0..count) {
            var domain = ""
            while (payload[offset] != 0) {
                for (i in 0..payload[offset]) {
                    domain += "${Rune(payload[offset + 1 + Int64(i)])}"
                }
                domain += "."
                offset += Int64(payload[offset]) + 1
            }
            domains.append(domain)
        }
        return domains.toArray()
    }

    public func canAccept(socket: TunSocket, firstDataPacket: IPPacket): Bool {
        if (socket.protocol != ProtocolUdp || socket.destinationPort != 53) {
            return false
        }
        let requestDomains = getRequestDomains(firstDataPacket.udpPayload())
        for (domain in requestDomains) {
            let parts = domain.split(".", removeEmpty: true)
            var inMap = domains
            for (index in (parts.size - 1)..=0 : -1) {
                let result = inMap.get(parts[index])
                if (result.isNone()) {
                    break
                }
                inMap = (result.getOrThrow() as HashMap<String, Any>).getOrThrow()
            }
            if (inMap.get("").isSome()) {
                return true
            }
        }
        return false
    }
}

public open class TunSocket {
    let manager: TunSocketManager
    let protocol: UInt8
    let sourceIP: Array<UInt8>
    let sourcePort: UInt16
    let destinationIP: Array<UInt8>
    let destinationPort: UInt16
    var closed = false
    var lastSentTimestamp = 0
    var lastReceivedTimestamp = 0

    init(manager: TunSocketManager, protocol: UInt8, sourceIP: Array<UInt8>, sourcePort: UInt16,
        destinationIP: Array<UInt8>, destinationPort: UInt16) {
        this.manager = manager
        this.protocol = protocol
        this.sourceIP = sourceIP
        this.sourcePort = sourcePort
        this.destinationIP = destinationIP
        this.destinationPort = destinationPort
    }

    public func isClosed(): Bool {
        closed
    }

    public open func read(buffer: Array<UInt8>): Int64 {
        -1
    }

    public open func write(data: Array<UInt8>): Int64 {
        -1
    }

    public open func close() {
        return
    }
}

public class TunUdpSocket <: TunSocket {
    let packets: BlockingQueue<IPPacket>

    init(manager: TunSocketManager, sourceIP: Array<UInt8>, sourcePort: UInt16, destinationIP: Array<UInt8>,
        destinationPort: UInt16, packetBufferSize!: Int64 = 100) {
        super(manager, ProtocolUdp, sourceIP, sourcePort, destinationIP, destinationPort)
        this.packets = BlockingQueue<IPPacket>(packetBufferSize)
    }

    func enqueue(packet: IPPacket): Bool {
        lastReceivedTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        packets.tryEnqueue(packet)
    }

    public override func read(buffer: Array<UInt8>): Int64 {
        if (closed) {
            return -1
        }
        var packet: ?IPPacket = None
        while (packet.isNone()) {
            packet = packets.dequeue(Duration.millisecond * 100)
            if (packet.isNone() && closed) {
                return -1
            }
        }
        let payload = packet.getOrThrow().udpPayload()
        let size = min(payload.size, buffer.size)
        payload.copyTo(buffer, 0, 0, size)
        packet?.release()
        return size
    }

    public override func write(data: Array<UInt8>): Int64 {
        if (closed) {
            return -1
        }
        var result = manager.send(this, data)
        lastSentTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        return result
    }

    public override func close() {
        if (closed) {
            return
        }
        closed = true
        manager.terminate(this)
    }
}

type TcpServerState = UInt8

const Unknown: TcpServerState = 0
const SocketInit: TcpServerState = Unknown + 1
const SynReceived: TcpServerState = SocketInit + 1
const Established: TcpServerState = SocketInit + 2
const FinWait1: TcpServerState = SocketInit + 3
const FinWait2: TcpServerState = SocketInit + 4
const TimeWait: TcpServerState = SocketInit + 5
const CloseWait: TcpServerState = SocketInit + 6
const LastAck: TcpServerState = SocketInit + 7
const Closed: TcpServerState = SocketInit + 8

public class TunTcpSocket <: TunSocket {
    let readMutex = ReentrantMutex()
    let readBuffer: Array<UInt8>
    var startIndexOfReadableData: Int64 = 0
    var readableDataSize: Int64 = 0

    let writeMutex = ReentrantMutex()
    let writeBuffer: Array<UInt8>
    var startIndexOfWritableData: Int64 = 0
    var writableDataSize: Int64 = 0
    var remoteNextSequenceNumber: UInt32 = 0
    var remoteAcknowledgementNumber: UInt32 = 0
    var remoteWindowSize: UInt16 = 0
    var localAcknowledgementNumber: UInt32 = 0
    var localAcknowledgementNumberAckCounter = 0
    var localNextSequenceNumber: UInt32 = 0
    var sentLocalWindowSize: UInt16 = 0

    var readClosed = false
    var internalState: TcpServerState = SocketInit
    var closedTimestamp = 0
    mut prop state: TcpServerState {
        get() {
            internalState
        }
        set(v) {
            internalState = v
            if (v == CloseWait || v == FinWait1) {
                if (closedTimestamp == 0) {
                    closedTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
                }
            }
            if (v == CloseWait || v == TimeWait) {
                readClosed = true
            }
        }
    }

    init(manager: TunSocketManager, sourceIP: Array<UInt8>, sourcePort: UInt16, destinationIP: Array<UInt8>,
        destinationPort: UInt16, readBufferSize!: Int64 = Int64(UInt16.Max), writeBufferSize!: Int64 = Int64(UInt16.Max)) {
        super(manager, ProtocolTcp, sourceIP, sourcePort, destinationIP, destinationPort)
        readBuffer = Array<UInt8>(readBufferSize, item: 0)
        writeBuffer = Array<UInt8>(writeBufferSize, item: 0)
    }

    func getLocalRemainingWindowSize(): UInt16 {
        readMutex.lock()
        let remainingSize = readBuffer.size - readableDataSize
        readMutex.unlock()
        if (remainingSize > Int64(UInt16.Max)) {
            return UInt16.Max
        }
        return UInt16(remainingSize)
    }

    func getRemoteRemainingWindowSize(): UInt16 {
        writeMutex.lock()
        let remainingSize = Int64(remoteWindowSize) -
            (Int64(localNextSequenceNumber) + Int64(UInt32.Max) - Int64(localAcknowledgementNumber)) % Int64(UInt32.Max)
        writeMutex.unlock()
        if (remainingSize > Int64(UInt16.Max)) {
            return UInt16.Max
        }
        if (remainingSize < 0) {
            return 0
        }
        return UInt16(remainingSize)
    }

    func setRemoteWindowSize(windowSize: UInt16, acknowledgementNumber: UInt32) {
        writeMutex.lock()
        if (acknowledgementNumber > localAcknowledgementNumber) {
            remoteWindowSize = windowSize
            localAcknowledgementNumber = acknowledgementNumber
            localAcknowledgementNumberAckCounter = 0
        }
        if (acknowledgementNumber == localAcknowledgementNumber) {
            localAcknowledgementNumberAckCounter++
        }
        writeMutex.unlock()
    }

    @OverflowWrapping
    func offloadPayload(payload: Array<UInt8>): Bool {
        if (readClosed) {
            return false
        }
        lastReceivedTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        try {
            readMutex.lock()
            let remainingSize = readBuffer.size - readableDataSize
            if (payload.size > remainingSize) {
                return false
            }
            let payloadIndex = (startIndexOfReadableData + readableDataSize) % readBuffer.size
            let copiedSize = min(payload.size, readBuffer.size - payloadIndex)
            payload.copyTo(readBuffer, 0, payloadIndex, copiedSize)
            if (copiedSize < payload.size) {
                payload.copyTo(readBuffer, copiedSize, 0, payload.size - copiedSize)
            }
            readableDataSize += payload.size
            remoteNextSequenceNumber += UInt32(payload.size)
            return true
        } finally {
            readMutex.unlock()
        }
    }

    @OverflowWrapping
    public override func read(buffer: Array<UInt8>): Int64 {
        while (true) {
            if (readableDataSize > 0) {
                readMutex.lock()
                let sizeToCopy = min(buffer.size, readableDataSize)
                let copiedSize = min(sizeToCopy, readBuffer.size - startIndexOfReadableData)
                readBuffer.copyTo(buffer, startIndexOfReadableData, 0, copiedSize)
                if (copiedSize < sizeToCopy) {
                    readBuffer.copyTo(buffer, 0, copiedSize, sizeToCopy - copiedSize)
                }
                startIndexOfReadableData = (startIndexOfReadableData + sizeToCopy) % readBuffer.size
                readableDataSize -= sizeToCopy
                return sizeToCopy
                readMutex.unlock()
            }
            if (readClosed) {
                return -1
            }
            sleep(Duration.millisecond * 10)
        }
        return -1
    }

    @OverflowWrapping
    public override func write(payload: Array<UInt8>): Int64 {
        if (closed) {
            return -1
        }
        var remainingDataSize = payload.size
        while (remainingDataSize > 0 && !closed) {
            var remainingBufferSize = writeBuffer.size - writableDataSize
            if (remainingBufferSize <= 0) {
                sleep(Duration.millisecond * 10)
                continue
            }
            writeMutex.lock()
            remainingBufferSize = writeBuffer.size - writableDataSize
            if (remainingBufferSize <= 0) {
                continue
            }
            let payloadIndex = (startIndexOfWritableData + writableDataSize) % writeBuffer.size
            let sizeToCopy = min(remainingDataSize, writeBuffer.size - writableDataSize)
            let copiedSize = min(sizeToCopy, readBuffer.size - startIndexOfReadableData)
            payload.copyTo(writeBuffer, payload.size - remainingDataSize, payloadIndex, copiedSize)
            if (copiedSize < sizeToCopy) {
                payload.copyTo(writeBuffer, payload.size - remainingDataSize - copiedSize, 0, sizeToCopy - copiedSize)
            }
            writableDataSize += sizeToCopy
            remainingDataSize -= sizeToCopy
            lastSentTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
            writeMutex.unlock()
        }
        return payload.size - remainingDataSize
    }

    public override func close() {
        closed = true
        manager.terminate(this)
    }
}
