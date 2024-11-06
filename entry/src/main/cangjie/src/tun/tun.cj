/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import std.collection.concurrent.BlockingQueue
import std.collection.HashMap
import std.os.posix.read
import ohos.hilog.Hilog
import std.sync.sleep
import std.time.Duration
import net.http.ClientBuilder
import std.os.posix.write

const IPPacketMaxSize = 1500

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

    func srcIP(): Array<UInt8> {
        data.slice(12, 4).clone()
    }

    func srcIPString(): String {
        let ip = data.slice(12, 4)
        "${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}"
    }

    func setSrcIP(newIP: Array<UInt8>) {
        newIP.copyTo(data, 0, 12, 4)
    }

    func destIP(): Array<UInt8> {
        data.slice(16, 4).clone()
    }

    func destIPString(): String {
        let ip = data.slice(16, 4)
        "${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}"
    }

    func setDestIP(newIP: Array<UInt8>) {
        newIP.copyTo(data, 0, 16, 4)
    }

    func validateIPHeader(): Bool {
        sum(data.slice(0, headerLength())) == 0xffff
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

    func resumIPHeader() {
        data[10] = 0
        data[11] = 0
        let result = sum(data.slice(0, headerLength()))
        data[10] = UInt8(result >> 8)
        data[11] = UInt8(result)
    }

    func sum(data: Array<UInt8>): UInt16 {
        var result: UInt32 = 0
        for (i in 0..data.size - 1 : 2) {
            result += UInt32(data[i]) << 8 + UInt32(data[i + 1])
        }
        if (data.size % 2 == 1) {
            result += UInt32(data[data.size - 1]) << 8
        }
        while ((result & 0xffff0000) != 0) {
            result = result >> 16 + result & 0x0000ffff
        }
        return !UInt16(result)
    }

    func sumWithPseudoIPHeader(data: Array<UInt8>): UInt16 {
        let pseudoHeader = Array<UInt8>(12, item: 0)
        data.copyTo(pseudoHeader, 12, 0, 4)
        data.copyTo(pseudoHeader, 16, 4, 4)
        pseudoHeader[9] = data[9]
        pseudoHeader[10] = UInt8(data.size >> 8)
        pseudoHeader[11] = UInt8(data.size)
        let pseudoHeaderSum = sum(pseudoHeader)
        let dataSum = sum(data)
        var result = UInt32(!pseudoHeaderSum) + UInt32(!dataSum)
        while ((result & 0xffff0000) != 0) {
            result = result >> 16 + result & 0x0000ffff
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

public interface IPProtocolStack {
    func protocol(): UInt8
    func pop(packet: IPPacket): Unit
}

public class TunDevice {
    // Tun 设备文件描述符
    let tunFd: Int32
    var runing: Bool = false
    let stacks = HashMap<UInt8, IPProtocolStack>()
    var pool: IPPacketPool
    var reader: ?Future<Unit> = None

    public init(fd: Int32) {
        this(fd, IPPacketPool(1000))
    }

    public init(fd: Int32, pool: IPPacketPool) {
        tunFd = fd
        this.pool = pool
    }

    public func register(stack: IPProtocolStack) {
        stacks.put(stack.protocol(), stack)
    }

    public func start() {
        runing = true
        reader = spawn {
            readLoop()
        }
    }

    public func stop() {
        if (!runing) {
            return
        }
        runing = false
        reader?.get()
    }

    private func readLoop() {
        unsafe {
            var buffer = LibC.malloc<UInt8>(count: IPPacketMaxSize)
            while (runing) {
                let size = read(tunFd, buffer, UIntNative(IPPacketMaxSize))

                if (size == -1) {
                    sleep(Duration.millisecond * 10)
                    continue
                }

                let packet = pool.getPacket()
                for (i in 0..Int64(size)) {
                    packet.data[i] = buffer.read(i)
                }
                if (!packet.isIPv4()) {
                    continue
                }
                if (packet.length() != Int64(size)) {
                    packet.release()
                    continue
                }
                match (stacks.get(packet.protocol())) {
                    case Some(stack) => stack.pop(packet)
                    case _ => packet.release()
                }
            }
            LibC.free(buffer)
        }
    }

    func writePacket(packet: IPPacket) {
        unsafe {
            var buffer = LibC.malloc<UInt8>(count: IPPacketMaxSize)
            for (i in 0..packet.length()) {
                buffer.write(i, packet.data[i])
            }
            let count = write(tunFd, buffer, UIntNative(packet.length()))
            LibC.free(buffer)
            return count
        }
    }
}
