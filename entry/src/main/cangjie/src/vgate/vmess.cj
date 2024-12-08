/**
 * Created on 2024/11/11
 */
package ohos_app_cangjie_entry.vgate

import std.collection.ArrayList
import std.socket.*
import encoding.hex.fromHexString
import std.time.*
import net.http.Protocol
import crypto.digest.MD5
import std.binary.*
import std.random.Random
import std.math.*
import ohos.hilog.Hilog
import ohos.crypto.createSymKeyGenerator
import ohos.crypto.createMac
import ohos.crypto.createCipher
import ohos.crypto.DataBlob
import ohos.crypto.CryptoMode
import ohos.crypto.GcmParamsSpec
import ohos.crypto.IvParamsSpec
import crypto.crypto.SecureRandom

public class VmessConnection <: StreamingSocket {
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
    var domain = Array<UInt8>()
    var port = UInt16(0)

    var requestKey = Array<UInt8>()
    var requestIV = Array<UInt8>()
    var requestCount = UInt16(0)
    var v = UInt8(0)
    var responseKey = Array<UInt8>()
    var responseIV = Array<UInt8>()
    var responseCount = UInt16(0)
    var responseRemainingBuffer = Array<UInt8>()

    public prop localAddress: SocketAddress {
        get() {
            socket.localAddress
        }
    }
    public prop remoteAddress: SocketAddress {
        get() {
            socket.remoteAddress
        }
    }
    public mut prop readTimeout: ?Duration {
        get() {
            socket.readTimeout
        }
        set(v) {
            socket.readTimeout = v
        }
    }
    public mut prop writeTimeout: ?Duration {
        get() {
            socket.writeTimeout
        }
        set(v) {
            socket.writeTimeout = v
        }
    }

    public init(userId: String, server: String, port: UInt16) {
        id = fromHexString(userId.replace("-", "")).getOrThrow()
        let chars = ArrayList<UInt8>()
        for (char in "c48619fe-8f02-49e0-b9e9-edf763e17e21") {
            chars.append(char)
        }
        appendId = chars.toArray()
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
        var addressLength = 4
        if (domain.size > 0) {
            addressLength = 1 + domain.size
        }
        let buffer = Array<UInt8>(
            16 /*Auth*/ + 1 /*Ver*/ + 16 /*IV*/ + 16 /*Key*/ + 1 /*V*/ + 1 /*Opt*/ + 1 /*P+Sec*/ + 1 /*Reserved*/ + 1 /*Cmd*/ + 2 /*Port*/ + 1 /*T*/ + addressLength /*A*/ + 4 /*F*/ ,
            item: 0
        )
        let r = SecureRandom()
        var offset = 0
        let timestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        let timestampOffset = Int64(r.nextUInt8(58)) - 29
        let timestampBuffer = Array<UInt8>(8, item: 0)
        (timestamp + timestampOffset).writeBigEndian(timestampBuffer)
        let hmacKey = createSymKeyGenerator("HMAC").convertKey(DataBlob(id))
        let hmac = createMac("MD5")
        hmac.`init`(hmacKey)
        hmac.update(DataBlob(timestampBuffer))
        /*Auth*/
        var macdata = hmac.doFinal()
        macdata.data.copyTo(buffer, 0, offset, 16)

        offset += 16
        /*Ver*/ buffer[offset] = 1

        offset += 1
        requestIV = Array<UInt8>(16, item: 0)
        for (i in 0..16) {
            requestIV[i] = r.nextUInt8()
        }
        /*IV*/ requestIV.copyTo(buffer, 0, offset, 16)
        let md5IV2 = MD5()
        md5IV2.write(requestIV)
        responseIV = md5IV2.finish()

        offset += 16
        requestKey = Array<UInt8>(16, item: 0)
        for (i in 0..16) {
            requestKey[i] = r.nextUInt8()
        }
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
        if (protocol == ProtocolTcp) {
            /*Cmd*/ buffer[offset] = 0x1
        } else {
            /*Cmd*/ buffer[offset] = 0x2
        }
        offset += 1
        /*Port*/ port.writeBigEndian(buffer.slice(offset, 2))
        offset += 2
        if (domain.size > 0) {
            /*T*/ buffer[offset] = 0x2
            offset += 1
            /*AS*/ buffer[offset] = UInt8(domain.size)
            offset += 1
            /*A*/ domain.copyTo(buffer, 0, offset, domain.size)
            offset += domain.size
        } else {
            /*T*/ buffer[offset] = 0x1
            offset += 1
            /*A*/ address.copyTo(buffer, 0, offset, 4)
            offset += 4
        }
        /*F*/ fnv32a(buffer.slice(16, buffer.size - 16 - 4)).copyTo(buffer, 0, offset, 4)

        let md5IV = MD5()
        md5IV.write(timestampBuffer)
        md5IV.write(timestampBuffer)
        md5IV.write(timestampBuffer)
        md5IV.write(timestampBuffer)
        let requestHeaderIV = md5IV.finish()

        let md5Key = MD5()
        md5Key.write(id)
        md5Key.write(appendId)
        let requestHeaderKey = md5Key.finish()

        let symKeyGenerator = createSymKeyGenerator("AES128")
        let key = symKeyGenerator.convertKey(DataBlob(requestHeaderKey))
        let params = IvParamsSpec("AES128", DataBlob(requestHeaderIV))
        let cipher = createCipher("AES128|CFB|NoPadding")
        cipher.`init`(CryptoMode.ENCRYPT_MODE, key, params)
        let blob = cipher.update(DataBlob(buffer.slice(16, buffer.size - 16)))
        cipher.doFinal(None)
        blob.data.copyTo(buffer, 0, 16, blob.data.size)

        socket.write(buffer)
        requestHeaderWrote = true
    }

    func readResponseHeader(): Int64 {
        let buffer = Array<UInt8>(4, item: 0)
        var count = socket.read(buffer)
        if (count != 4) {
            return -1
        }

        let symKeyGenerator = createSymKeyGenerator("AES128")
        let key = symKeyGenerator.convertKey(DataBlob(responseKey))
        let params = IvParamsSpec("AES128", DataBlob(responseIV))
        let cipher = createCipher("AES128|CFB|NoPadding")
        cipher.`init`(CryptoMode.DECRYPT_MODE, key, params)
        let blob = cipher.update(DataBlob(buffer))
        cipher.doFinal(None)

        if ( /*V*/ blob.data[0] != v) {
            return -1
        }
        if ( /*M*/ blob.data[3] > 0) {
            var skipBuffer = Array<UInt8>(Int64(blob.data[3]), item: 0)
            count += socket.read(skipBuffer)
            if (count != (4 + Int64(blob.data[3]))) {
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

    public func setHeaderWithDomain(protocol: UInt8, domain: String, port: UInt16) {
        this.protocol = protocol
        this.domain = domain.toArray()
        this.port = port
    }

    public func write(payload: Array<UInt8>) {
        if (!requestHeaderWrote) {
            writeRequestHeader()
        }
        var sentSize = 0
        while (sentSize < payload.size) {
            var bodyLength = payload.size - sentSize
            if (bodyLength > 64992) {
                bodyLength = 64992
            }

            let symKeyGenerator = createSymKeyGenerator("AES128")
            let key = symKeyGenerator.convertKey(DataBlob(requestKey))
            let newIV = Array<UInt8>(12, item: 0)
            requestCount.writeBigEndian(newIV)
            requestIV.copyTo(newIV, 2, 2, 10)
            let params = GcmParamsSpec("AES128", DataBlob(newIV), DataBlob(), DataBlob())
            let cipher = createCipher("AES128|GCM|PKCS7")
            cipher.`init`(CryptoMode.ENCRYPT_MODE, key, params)
            let encryptedData = cipher.update(DataBlob(payload.slice(sentSize, bodyLength)))
            let gcmData = cipher.doFinal(None)

            var buffer = Array<UInt8>(2, item: 0)
            let size = UInt16(encryptedData.data.size) + UInt16(gcmData.data.size)
            size.writeBigEndian(buffer)
            socket.write(buffer)
            socket.write(encryptedData.data)
            socket.write(gcmData.data)

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
            while (readSize < buffer.size) {
                let count = socket.read(buffer.slice(readSize, buffer.size - readSize))
                readSize += count
            }

            let symKeyGenerator = createSymKeyGenerator("AES128")
            let key = symKeyGenerator.convertKey(DataBlob(responseKey))
            let newIV = Array<UInt8>(12, item: 0)
            responseCount.writeBigEndian(newIV)
            responseIV.copyTo(newIV, 2, 2, 10)
            let params = GcmParamsSpec("AES128", DataBlob(newIV), DataBlob(), DataBlob(buffer.slice(buffer.size - 16, 16
            )))
            let cipher = createCipher("AES128|GCM|PKCS7")
            cipher.`init`(CryptoMode.DECRYPT_MODE, key, params)
            let decryptedData = cipher.update(DataBlob(buffer.slice(0, buffer.size - 16)))
            let gcmData = cipher.doFinal(None)
            if (gcmData.data.size != 0) {
                return -1
            }

            responseRemainingBuffer = decryptedData.data
            responseCount++
        }

        let copyLength = min(responseRemainingBuffer.size, payload.size)
        responseRemainingBuffer.copyTo(payload, 0, 0, copyLength)
        if (copyLength < responseRemainingBuffer.size) {
            responseRemainingBuffer = responseRemainingBuffer.slice(copyLength, responseRemainingBuffer.size - copyLength
            )
        } else {
            responseRemainingBuffer = Array<UInt8>()
        }
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
            socket.flush()
            socket.close()
        }
    }

    public func toString(): String {
        return "${socket.localAddress.toString()} -> ${socket.remoteAddress.toString()}"
    }
}

public class VmessProxyListener <: TunSocketListener {
    var destinationIP = Array<UInt8>()
    public VmessProxyListener(let userId: String, let server: String, let port: UInt16) {}

    public func accept(socket: TunSocket): Unit {
        spawn {
            redirect(socket)
        }
        return
    }

    public func dnat(destinationIP: Array<UInt8>): VmessProxyListener {
        this.destinationIP = destinationIP
        return this
    }

    func redirect(socket: TunSocket) {
        let vmess = VmessConnection(userId, server, port)
        try {
            vmess.connect()
            var ip = destinationIP
            if (ip.size <= 0) {
                ip = socket.destinationIP
            }
            vmess.setHeader(socket.protocol, ip, socket.destinationPort)

            Hilog.debug(0x1799, "VmessProxyListener",
                "VMESS(Start) Init ${socket.protocol} ${socket.sourceIP}:${socket.sourcePort} -> ${ip}:${socket.destinationPort}"
            )

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
                    if (!vmess.isClosed()) {
                        Hilog.error(0x1799, "VmessProxyListener",
                            "Receive ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
                    }
                } finally {
                    socket.close()
                    Hilog.debug(0x1799, "VmessProxyListener",
                        "VMESS Receive Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
                    )
                }
            }

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
            Hilog.error(0x1799, "VmessProxyListener",
                "Send ${socket.sourceIP}:${socket.sourcePort} ${exceptionToString(e)}")
        } finally {
            vmess.close()
            Hilog.debug(0x1799, "VmessProxyListener",
                "VMESS Send Done ${socket.sourceIP}:${socket.sourcePort} -> ${socket.destinationIP}:${socket.destinationPort}"
            )
        }
    }
}
