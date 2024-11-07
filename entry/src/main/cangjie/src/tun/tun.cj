/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import std.collection.HashMap
import std.os.posix.read
import std.sync.sleep
import std.time.Duration
import std.os.posix.write

public interface IPProtocolStack {
    func protocol(): UInt8
    func pop(packet: IPPacket): Unit
}

public class TunDevice {
    // Tun 设备文件描述符
    let tunFd: Int32
    var running: Bool = false
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
        running = true
        reader = spawn {
            readLoop()
        }
    }

    public func stop() {
        if (!running) {
            return
        }
        running = false
        reader?.get()
    }

    private func readLoop() {
        unsafe {
            try {
                var buffer = LibC.malloc<UInt8>(count: IPPacketMaxSize)
                while (running) {
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
            } catch (e: Exception) {
            }
        }
    }

    func write(ipPacket: Array<UInt8>): Int64 {
        unsafe {
            var buffer = LibC.malloc<UInt8>(count: ipPacket.size)
            for (i in 0..ipPacket.size) {
                buffer.write(i, ipPacket[i])
            }
            let count = write(tunFd, buffer, UIntNative(ipPacket.size))
            LibC.free(buffer)
            return Int64(count)
        }
    }
}
