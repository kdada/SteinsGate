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
    let packets: BlockingQueue<IPPacket>
    var closed = false
    var lastSentTimestamp = 0
    var lastReceivedTimestamp = 0

    init(manager: TunSocketManager, protocol: UInt8, sourceIP: Array<UInt8>, sourcePort: UInt16,
        destinationIP: Array<UInt8>, destinationPort: UInt16, packetBufferSize!: Int64 = 100) {
        this.manager = manager
        this.protocol = protocol
        this.sourceIP = sourceIP
        this.sourcePort = sourcePort
        this.destinationIP = destinationIP
        this.destinationPort = destinationPort
        this.packets = BlockingQueue<IPPacket>(packetBufferSize)
    }

    func remainingBufferCount(): Int64 {
        packets.capacity - packets.size
    }

    func enqueue(packet: IPPacket): Bool {
        lastReceivedTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        packets.tryEnqueue(packet)
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
    init(manager: TunSocketManager, sourceIP: Array<UInt8>, sourcePort: UInt16, destinationIP: Array<UInt8>,
        destinationPort: UInt16, packetBufferSize!: Int64 = 100) {
        super(manager, ProtocolUdp, sourceIP, sourcePort, destinationIP, destinationPort, packetBufferSize: packetBufferSize)
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