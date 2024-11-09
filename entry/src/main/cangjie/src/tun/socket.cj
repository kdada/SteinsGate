/**
 * Created on 2024/11/7
 */
package ohos_app_cangjie_entry.tun

import std.collection.concurrent.ArrayBlockingQueue
import std.math.min
import std.time.Duration
import std.sync.sleep
import std.time.DateTime
import std.sync.ReentrantMutex

public interface TunSocketManager {
    func send(socket: TunSocket, payload: Array<UInt8>): Int64
    func close(socket: TunSocket): Unit
}

public interface TunSocketHandler {
    func canHandle(socket: TunSocket): Bool
    func handle(socket: TunSocket): Unit
}

public open class TunSocket {
    let manager: TunSocketManager
    let protocol: UInt8
    let sourceIP: Array<UInt8>
    let sourcePort: UInt16
    let destinationIP: Array<UInt8>
    let destinationPort: UInt16
    let packets: ArrayBlockingQueue<IPPacket>
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
        this.packets = ArrayBlockingQueue<IPPacket>(packetBufferSize)
    }

    func remainingBufferCount(): Int64 {
        packets.capacity - packets.size
    }

    func enqueue(packet: IPPacket): Bool {
        lastReceivedTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        packets.tryEnqueue(packet)
    }

    public open func isClosed(): Bool {
        closed
    }

    public open func read(buffer: Array<UInt8>): Int64 {
        -1
    }

    public open func write(data: Array<UInt8>): Int64 {
        -1
    }

    public open func close() {
        closed = true
        manager.close(this)
        while (true) {
            let socket = packets.tryDequeue()
            if (socket.isNone()) {
                break
            }
            socket.getOrThrow().release()
        }
    }
}

public class TunUdpSocket <: TunSocket {
    init(manager: TunSocketManager, sourceIP: Array<UInt8>, sourcePort: UInt16, destinationIP: Array<UInt8>,
        destinationPort: UInt16, packetBufferSize!: Int64 = 100) {
        super(manager, 0x11, sourceIP, sourcePort, destinationIP, destinationPort, packetBufferSize: packetBufferSize)
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
}

enum TcpServerState {
    Init | SynReceived | Established | FinWait1 | FinWait2 | TimeWait | CloseWait | LastAck | Closed
}

public class TunTcpSocket <: TunSocket {
    let mutex: ReentrantMutex = ReentrantMutex()
    var lastReadPacket: ?IPPacket = None
    var lastReadBytes: Int64 = 0
    var internalState: TcpServerState = Init
    var closedTimestamp = 0
    mut prop state: TcpServerState {
        get() {
            Init
        }
        set(v) {
            internalState = v
            match (v) {
                case CloseWait | FinWait1 => {
                    => if (closedTimestamp == 0) {
                        closedTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
                    }
                }
                case _ => {=>}
            }
        }
    }
    var remoteSequenceNumber: UInt32 = 0
    var remoteWindow: UInt16 = 0
    var localSequenceNumber: UInt32 = 0
    var sentSequenceNumber: UInt32 = 0

    init(manager: TunSocketManager, sourceIP: Array<UInt8>, sourcePort: UInt16, destinationIP: Array<UInt8>,
        destinationPort: UInt16, packetBufferSize!: Int64 = 100) {
        super(manager, 0x6, sourceIP, sourcePort, destinationIP, destinationPort, packetBufferSize: packetBufferSize)
    }

    func remainingWindowSize(): UInt16 {
        let windowSize = remainingBufferCount() * (IPPacketMaxSize - 60 /*Max IP Header*/ - 60 /*Max TCP Header*/ )
        if (windowSize > (2 ** 16 - 1)) {
            return UInt16(2 ** 16 - 1)
        }
        return UInt16(windowSize)
    }

    public override func read(buffer: Array<UInt8>): Int64 {
        var readBytes = 0
        while (readBytes < buffer.size) {
            var packet: ?IPPacket = lastReadPacket
            var read = lastReadBytes
            if (packet.isNone()) {
                packet = packets.tryDequeue()
                if (packet.isNone()) {
                    if (readBytes > 0) {
                        return readBytes
                    }
                    while (packet.isNone()) {
                        packet = packets.dequeue(Duration.millisecond * 100)
                        if (packet.isNone() && closed) {
                            return -1
                        }
                    }
                }
            }
            let payload = packet.getOrThrow().tcpPayload()
            let bytesToCopy = min(buffer.size - readBytes, payload.size - read)
            payload.copyTo(buffer, readBytes, read, bytesToCopy)
            readBytes += bytesToCopy
            read += bytesToCopy
            if (read < payload.size) {
                lastReadPacket = packet
                lastReadBytes = read
            } else {
                if (packet.isSome()) {
                    packet.getOrThrow().release()
                }
                lastReadPacket = None
                lastReadBytes = 0
            }
        }
        return readBytes
    }

    @OverflowWrapping
    public override func write(data: Array<UInt8>): Int64 {
        if (closed) {
            return -1
        }
        var remainingDataSize = data.size
        while (remainingDataSize > 0 && !closed) {
            let remainingRemoteWindow = Int64(remoteWindow) - Int64(localSequenceNumber + 1 - sentSequenceNumber)
            let minPayloadSize = 1400
            if (remainingRemoteWindow >= remainingDataSize || remainingRemoteWindow >= minPayloadSize) {
                let payload = data.slice(data.size - remainingDataSize, min(remainingDataSize, minPayloadSize))
                manager.send(this, payload)
                lastSentTimestamp = DateTime.now().toUnixTimeStamp().toSeconds()
                remainingDataSize -= payload.size
            } else {
                sleep(Duration.millisecond * 10)
            }
        }
        return data.size - remainingDataSize
    }
}
