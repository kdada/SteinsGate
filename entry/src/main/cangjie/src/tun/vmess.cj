/**
 * Created on 2024/11/11
 */
package ohos_app_cangjie_entry.tun

import std.socket.*
import encoding.hex.fromHexString
import std.time.*
import net.http.Protocol
import crypto.digest.MD5
import std.binary.*
import std.random.Random
import std.math.*
import ohos.hilog.Hilog

public class VmessConnection {
    let id: Array<UInt8>
    let appendId: Array<UInt8>
    let serverAddress: SocketAddress
    let socket: TcpSocket
    var connected = false
    var requestHeaderWrote = false
    var responseHeaderRead = false
    var closed = false

    var protocol = UInt8(0)
    var address = Array<UInt8>()
    var port = UInt16(0)

    var requestKey = Array<UInt8>()
    var requestIV = Array<UInt8>()
    var requestCount = UInt16(0)
    var v = UInt8(0)
    var responseKey = Array<UInt8>()
    var responseIV = Array<UInt8>()
    var responseCount = UInt16(0)
    var responseRemainingBuffer = Array<UInt8>()

    public init(userId: String, server: String, port: UInt16) {
        id = fromHexString(userId.replace("-", "")).getOrThrow()
        appendId = fromHexString("c48619fe-8f02-49e0-b9e9-edf763e17e21".replace("-", "")).getOrThrow()
        serverAddress = SocketAddress(server, port)
        socket = TcpSocket(serverAddress)
    }

    public func connect() {
        let timeout = Duration.second * tcpSessionTimeout
        socket.writeTimeout = timeout
        socket.connect(timeout: timeout)
        connected = true
    }

    @OverflowWrapping
    func fnv32a(data: Array<UInt8>): Array<UInt8> {
        var offset: UInt32 = 2166136261
        for (byte in data) {
            offset ^= UInt32(byte)
            offset *= 16777619
        }
        let buffer = Array<UInt8>(4, item: 0)
        offset.writeBigEndian(buffer)
        return buffer
    }

    func writeRequestHeader() {
        let buffer = Array<UInt8>(
            1 /*Ver*/ + 16 /*IV*/ + 16 /*Key*/ + 1 /*V*/ + 1 /*Opt*/ + 1 /*P+Sec*/ + 1 /*Reserved*/ + 1 /*Cmd*/ + 2 /*Port*/ + 1 /*T*/ + 4 /*A*/ + 4 /*F*/ ,
            item: 0
        )
        var offset = 0
        /*Ver*/ buffer[offset] = 1

        offset += 1
        let timestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        let timestampBuffer = Array<UInt8>(8, item: 0)
        timestamp.writeBigEndian(timestampBuffer)
        let md5IV = MD5()
        md5IV.write(timestampBuffer)
        md5IV.write(timestampBuffer)
        md5IV.write(timestampBuffer)
        md5IV.write(timestampBuffer)
        requestIV = md5IV.finish()
        /*IV*/ requestIV.copyTo(buffer, 0, offset, 16)
        let md5IV2 = MD5()
        md5IV2.write(requestIV)
        responseIV = md5IV2.finish()

        offset += 16
        let md5Key = MD5()
        md5Key.write(id)
        md5Key.write(appendId)
        requestKey = md5Key.finish()
        /*Key*/ requestKey.copyTo(buffer, 0, offset, 16)

        let md5Key2 = MD5()
        md5Key2.write(requestKey)
        responseKey = md5Key2.finish()

        offset += 16
        v = Random(UInt64(timestamp)).nextUInt8()
        /*V*/ buffer[offset] = v
        offset += 1
        /*Opt*/ buffer[offset] = 0x1
        offset += 1
        /*P+Sec*/ buffer[offset] = 0x3
        offset += 2
        if (protocol == 0x6) {
            /*Cmd*/ buffer[offset] = 0x1
        } else {
            /*Cmd*/ buffer[offset] = 0x2
        }
        offset += 1
        /*Port*/ port.writeBigEndian(buffer.slice(offset, 2))
        offset += 2
        /*T*/ buffer[offset] = 0x1
        offset += 1
        /*A*/ address.copyTo(buffer, 0, offset, 4)
        /*F*/ fnv32a(buffer.slice(0, buffer.size - 4)).copyTo(buffer, 0, offset, 4)

        // TODO AES-128-CFB for buffer

        socket.write(buffer)
        requestHeaderWrote = true
    }

    func readResponseHeader(): Int64 {
        let buffer = Array<UInt8>(4, item: 0)
        var count = socket.read(buffer)
        if (count != 4) {
            return -1
        }

        // TODO AES-128-CFB for buffer

        if ( /*V*/ buffer[0] != v) {
            return -1
        }
        if ( /*M*/ buffer[3] > 0) {
            var skipBuffer = Array<UInt8>(Int64(buffer[3]), item: 0)
            count += socket.read(skipBuffer)
            if (count != (4 + Int64(buffer[3]))) {
                return -1
            }
        }
        responseHeaderRead = true
        count
    }

    public func setHeader(protocol: UInt8, address: Array<UInt8>, port: UInt16) {
        this.protocol = protocol
        this.address = address
        this.port = port
    }

    public func write(payload: Array<UInt8>) {
        if (!requestHeaderWrote) {
            writeRequestHeader()
        }
        var sentSize = 0
        while (sentSize < payload.size) {
            var bodyLength = payload.size - sentSize
            if (bodyLength > 65000) {
                bodyLength = 65000
            }
            let size = UInt16(bodyLength)
            var buffer = Array<UInt8>(2 + bodyLength + 16, item: 0)
            size.writeBigEndian(buffer)
            payload.copyTo(buffer, sentSize, 2, bodyLength)

            // TODO AES-128-GCM for buffer

            socket.write(buffer)
            sentSize += bodyLength
            requestCount++
        }
    }

    public func read(payload: Array<UInt8>): Int64 {
        if (!responseHeaderRead) {
            if (readResponseHeader() < 0) {
                return -1
            }
        }
        if (responseRemainingBuffer.size <= 0) {
            var lengthBuffer = Array<UInt8>(2, item: 0)
            let count = socket.read(lengthBuffer)
            if (count != 2) {
                return -1
            }
            let length = UInt16.readBigEndian(lengthBuffer)
            let buffer = Array<UInt8>(Int64(length), item: 0)
            var readSize = 0
            while (readSize < payload.size) {
                let count = socket.read(payload.slice(readSize, payload.size - readSize))
                readSize += count
            }

            // TODO AES-128-GCM for buffer

            responseRemainingBuffer = buffer.slice(0, buffer.size - 16)
        }

        let copyLength = min(responseRemainingBuffer.size, payload.size)
        responseRemainingBuffer.copyTo(payload, 0, 0, copyLength)
        responseRemainingBuffer = responseRemainingBuffer.slice(copyLength, responseRemainingBuffer.size - copyLength)
        return copyLength
    }

    public open func isClosed(): Bool {
        closed
    }

    public func close() {
        closed = true
        if (!socket.isClosed()) {
            var buffer = Array<UInt8>(2, item: 0)
            socket.write(buffer)
            socket.close()
        }
    }
}

public class VmessProxyListener <: TunSocketListener {
    public VmessProxyListener(let userId: String, let server: String, let port: UInt16) {}

    public func accept(socket: TunSocket): Unit {
        spawn {
            redirect(socket)
        }
        return
    }

    func redirect(socket: TunSocket) {
        let vmess = VmessConnection(userId, server, port)
        try {
            vmess.connect()
            spawn {
                try {
                    var buffer = Array<UInt8>(tcpMaxPayloadSize, item: 0)
                    while (!socket.isClosed() && !vmess.isClosed()) {
                        let dataSize = vmess.read(buffer)
                        if (dataSize < 0) {
                            break
                        }
                        if (dataSize == 0 || dataSize > buffer.size) {
                            continue
                        }
                        socket.write(buffer.slice(0, dataSize))
                    }
                } catch (e: Exception) {
                    Hilog.error(0, "VmessProxyListener",
                        "Receive ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
                } finally {
                    Hilog.debug(0, "VmessProxyListener",
                        "VMESS Receive Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                    socket.close()
                }
            }


            vmess.setHeader(socket.protocol, socket.destinationIP, socket.destinationPort)
            var buffer = Array<UInt8>(tcpMaxPayloadSize, item: 0)
            while (!socket.isClosed() && !vmess.isClosed()) {
                let count = socket.read(buffer)
                if (count < 0) {
                    break
                }
                if (count == 0) {
                    continue
                }
                vmess.write(buffer.slice(0, count))
            }
        } catch (e: Exception) {
            Hilog.error(0, "VmessProxyListener", "Send ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
        } finally {
            Hilog.debug(0, "VmessProxyListener",
                "VMESS Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
            vmess.close()
        }
    }
}
