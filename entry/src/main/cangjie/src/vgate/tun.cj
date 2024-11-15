/**
 * Created on 2024/11/13
 */
package ohos_app_cangjie_entry.vgate

import std.collection.*
import std.collection.concurrent.*
import std.os.posix.*
import std.sync.*
import ohos.hilog.*
import std.time.*
import std.core.*
import std.socket.*

public interface IPProtocolStack {
    func protocol(): UInt8
    func enqueue(packet: IPPacket): Bool
    func close(): Unit
}

public class TunDevice {
    let tunFd: Int32
    var closed: Bool = false
    let stacks = HashMap<UInt8, IPProtocolStack>()
    var pool: IPPacketPool
    var reader: ?Future<Unit> = None
    var writer: ?Future<Unit> = None
    var queue = NonBlockingQueue<IPPacket>()

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
        reader = spawn {readLoop()}
        writer = spawn {writeLoop()}
    }

    public func close() {
        if (closed) {
            return
        }
        closed = true
        for ((_, stack) in stacks) {
            stack.close()
        }
        reader?.get()
        writer?.get()
        while (let Some(packet) <- queue.dequeue()) {
            packet.release()
        }
    }

    private func readLoop() {
        var packet = pool.getPacket()
        while (!closed) {
            try {
                var readCount = 0
                unsafe {
                    let rawData = acquireArrayRawData(packet.data)
                    readCount = Int64(read(tunFd, rawData.pointer, UIntNative(packet.data.size)))
                    releaseArrayRawData(rawData)
                }

                if (readCount <= 0) {
                    sleep(Duration.millisecond * 10)
                    continue
                }

                if (packet.length() != Int64(readCount)) {
                    continue
                }

                if (!packet.isIPv4()) {
                    continue
                }

                if (let Some(stack) <- stacks.get(packet.protocol())) {
                    if (stack.enqueue(packet)) {
                        packet = pool.getPacket()
                    }
                }
            } catch (e: Exception) {
                Hilog.error(0, "TunDevice Read", exceptionToString(e))
            }
        }
        packet.release()
        return
    }

    private func writeLoop() {
        var packet: ?IPPacket = None
        while (!closed) {
            try {
                if (queue.size <= 0) {
                    sleep(Duration.millisecond * 10)
                    continue
                }
                packet = queue.dequeue()
                let p = packet.getOrThrow()
                unsafe {
                    let rawData = acquireArrayRawData(p.data)
                    write(tunFd, rawData.pointer, UIntNative(p.length()))
                    releaseArrayRawData(rawData)
                }
            } catch (e: Exception) {
                Hilog.error(0, "TunDevice Write", exceptionToString(e))
            } finally {
                packet?.release()
                packet = None
            }
        }
        packet?.release()
        return
    }

    func enqueue(packet: IPPacket): Bool {
        queue.enqueue(packet)
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
                        "Receive ${socket.destinationIP}:${socket.destinationPort} -> ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}"
                    )
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
