/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.vgate

import ohos.hilog.*
import std.collection.*
import std.collection.concurrent.*
import std.sync.*
import std.time.*
import std.socket.*
import std.random.*

const tcpSessionTimeout = 30
const tcpMaxPayloadSize = 1400

public class TcpStack <: IPProtocolStack & TunSocketManager {
    let handlers = ArrayList<TunSocketHandler>()
    let device: TunDevice
    let pool: IPPacketPool
    let sockets = ConcurrentHashMap<IPPair, TunTcpSocket>()
    var closed = false
    let queues: Array<BlockingQueue<IPPacket>>
    let routines: Array<?Future<Unit>>

    public init(device: TunDevice, pool: IPPacketPool, queueCount!: Int64 = 2, packetCapacity!: Int64 = 1000) {
        this.device = device
        this.pool = pool
        var count = queueCount
        if (count < 1) {
            count = 1
        }
        queues = Array<BlockingQueue<IPPacket>>(count, {_ => BlockingQueue<IPPacket>(packetCapacity)})
        routines = Array<?Future<Unit>>(count, item: None)
        for (index in 0..count) {
            let i = index
            routines[i] = spawn {handleLoop(queues[i])}
        }
    }

    func handleLoop(queue: BlockingQueue<IPPacket>) {
        while (!closed) {
            if (let Some(packet) <- queue.dequeue(Duration.millisecond * 100)) {
                handle(packet)
            }
        }
    }

    public func register(handler: TunSocketHandler) {
        handlers.append(handler)
    }

    public override func protocol(): UInt8 {
        return ProtocolTcp
    }

    public override func enqueue(packet: IPPacket) {
        let index = IPPair(packet.sourceIP(), packet.tcpSourcePort(), packet.destinationIP(),
            packet.tcpDestinationPort()).hashCode() % queues.size
        queues[index].tryEnqueue(packet)
    }

    func handle(packet: IPPacket) {
        let sourceIP = packet.sourceIP()
        let sourcePort = packet.udpSourcePort()
        let destinationIP = packet.destinationIP()
        let destinationPort = packet.udpDestinationPort()
        let pair = IPPair(sourceIP, sourcePort, destinationIP, destinationPort)
        var s = sockets.get(pair)
        if (s.isNone()) {
            s = TunTcpSocket(this, sourceIP, sourcePort, destinationIP, destinationPort)
            sockets.put(pair, s.getOrThrow())
        }
        let socket = s.getOrThrow()

        if (socket.state == SocketInit) {
            if (packet.tcpFlagSYN()) {
                socket.state = SynReceived
            }
        } else if (socket.state == SynReceived) {
            if (packet.tcpFlagACK() && packet.tcpAcknowledgementNumber() == socket.localNextSequenceNumber) {
                socket.state = Established
            }
            let payload = packet.tcpPayload()
            if (payload.size > 0) {
            	socket.offloadPayload(payload)
            }
        } else if (socket.state == Established) {
            let payload = packet.tcpPayload()
            if (payload.size > 0) {
            	socket.offloadPayload(payload)
            }
            if (packet.tcpFlagFIN()) {
                socket.state = CloseWait
            }
        } else if (socket.state == CloseWait) {

        } else if (socket.state == LastAck) {
            if (packet.tcpFlagACK()) {
                socket.state = Closed
            }
        } else if (socket.state == FinWait1) {
            if (packet.tcpFlagACK()) {
                socket.state = FinWait2
            }
            if (packet.tcpFlagFIN()) {
                socket.state = TimeWait
            }
        } else if (socket.state == FinWait2) {
            if (packet.tcpFlagFIN()) {
                socket.state = TimeWait
            }
        } else if (socket.state == TimeWait) {

        } else if (socket.state == Closed) {

        }
    }

    public func send(socket: TunSocket, payload: Array<UInt8>): Int64 {
        0
    }

    public func terminate(socket: TunSocket) {
        let tcpSocket = (socket as TunTcpSocket).getOrThrow()
        if (tcpSocket.state == Established) {
            tcpSocket.state = FinWait1
        } else if (tcpSocket.state == CloseWait) {
            tcpSocket.state = LastAck
        }
        return
    }

    public func close() {
    }
}
