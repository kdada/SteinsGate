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

    func payload(): Array<UInt8> {
        let headerLen = headerLength()
        data.slice(headerLen, length() - headerLen)
    }

    func protocol(): UInt8 {
        data[9]
    }

    func srcIP(): Array<UInt8> {
        data.slice(12, 4)
    }

    func srcIPString(): String {
        let ip = srcIP()
        "${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}"
    }

    func destIP(): Array<UInt8> {
        data.slice(16, 4)
    }

    func destIPString(): String {
        let ip = destIP()
        "${ip[0]}.${ip[1]}.${ip[2]}.${ip[3]}"
    }

    func release() {
        this.pool.packets.tryEnqueue(this)
    }
}

class IPPacketPool {
    let packets: BlockingQueue<IPPacket>

    init(capacity: Int64) {
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
    func pop(packet: IPPacket): Bool
}

public class TunDevice {
    // Tun 设备文件描述符
    let tunFd: Int32
    var runing: Bool = false
    let stacks = HashMap<UInt8, IPProtocolStack>()
    var pool = IPPacketPool(1000)
    var reader: ?Future<Unit> = None

    public init(fd: Int32) {
        tunFd = fd
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
}
