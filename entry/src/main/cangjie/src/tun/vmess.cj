/**
 * Created on 2024/11/11
 */
package ohos_app_cangjie_entry.tun

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
        let buffer = Array<UInt8>(
            16 /*Auth*/ + 1 /*Ver*/ + 16 /*IV*/ + 16 /*Key*/ + 1 /*V*/ + 1 /*Opt*/ + 1 /*P+Sec*/ + 1 /*Reserved*/ + 1 /*Cmd*/ + 2 /*Port*/ + 1 /*T*/ + 4 /*A*/ + 4 /*F*/ ,
            item: 0
        )
        var offset = 0
        let timestamp = DateTime.now().toUnixTimeStamp().toSeconds()
        let timestampBuffer = Array<UInt8>(8, item: 0)
        timestamp.writeBigEndian(timestampBuffer)
        let hmacKey = createSymKeyGenerator("HMAC").convertKey(DataBlob(id))
        let hmac = createMac("MD5")
        hmac.`init`(hmacKey)
        hmac.update(DataBlob(timestampBuffer))
        /*Auth*/
        var macdata = hmac.doFinal()
        //Hilog.debug(0, "VmessProxyListener",
        //    "VMESS Mac ${address}:${port} ${id} ${timestamp} ${timestampBuffer} ${macdata.data}")
        macdata.data.copyTo(buffer, 0, offset, 16)

        offset += 16
        /*Ver*/ buffer[offset] = 1

        offset += 1
        let r = SecureRandom()
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

        //Hilog.debug(0, "VmessProxyListener", "VMESS appendid ${address}:${port} ${id} ${appendId}")

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
        /*T*/ buffer[offset] = 0x1
        offset += 1
        /*A*/ address.copyTo(buffer, 0, offset, 4)
        offset += 4
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
        //Hilog.debug(0, "VmessProxyListener",
        //    "VMESS cipher ${address}:${port} ${id} ${timestamp} ${timestampBuffer} ${requestIV} ${requestIV} ${buffer} ${blob.data}"
        //)
        blob.data.copyTo(buffer, 0, 16, blob.data.size)

        socket.write(buffer)
        requestHeaderWrote = true
    }

    func readResponseHeader(): Int64 {
        let buffer = Array<UInt8>(4, item: 0)
        //Hilog.debug(0, "VmessProxyListener", "VMESS start to read head ${buffer}")
        var count = socket.read(buffer)
        //Hilog.debug(0, "VmessProxyListener", "VMESS read ${buffer} ${count}")
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

        //Hilog.debug(0, "VmessProxyListener", "VMESS read ${buffer} ${blob.data}")

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
        //Hilog.debug(0, "VmessProxyListener", "VMESS read done ${buffer} ${blob.data}")
        responseHeaderRead = true
        count
    }

    public func setHeader(protocol: UInt8, address: Array<UInt8>, port: UInt16) {
        this.protocol = protocol
        this.address = address
        this.port = port
    }

    public func write(payload: Array<UInt8>) {
        //Hilog.debug(0, "VmessProxyListener", "VMESS write to header ${address}")
        if (!requestHeaderWrote) {
            writeRequestHeader()
        }
        //Hilog.debug(0, "VmessProxyListener", "VMESS write payload ${address}")
        var sentSize = 0
        while (sentSize < payload.size) {
            var bodyLength = payload.size - sentSize
            if (bodyLength > 64992) {
                bodyLength = 64992
            }

            //Hilog.debug(0, "VmessProxyListener", "VMESS write payload ${address} ${bodyLength}")

            let symKeyGenerator = createSymKeyGenerator("AES128")
            let key = symKeyGenerator.convertKey(DataBlob(requestKey))
            let newIV = Array<UInt8>(12, item: 0)
            requestCount.writeBigEndian(newIV)
            requestIV.copyTo(newIV, 2, 2, 10)
            //Hilog.debug(0, "VmessProxyListener", "VMESS new iv ${address} ${requestIV} ${newIV}")
            let params = GcmParamsSpec("AES128", DataBlob(newIV), DataBlob(), DataBlob())
            let cipher = createCipher("AES128|GCM|PKCS7")
            cipher.`init`(CryptoMode.ENCRYPT_MODE, key, params)
            let encryptedData = cipher.update(DataBlob(payload.slice(sentSize, bodyLength)))
            let gcmData = cipher.doFinal(None)
            //Hilog.debug(0, "VmessProxyListener",
            //    "VMESS encrypt ${address} ${encryptedData.data.size} ${gcmData.data.size}")

            var buffer = Array<UInt8>(2, item: 0)
            let size = UInt16(encryptedData.data.size) + UInt16(gcmData.data.size)
            size.writeBigEndian(buffer)
            socket.write(buffer)
            socket.write(encryptedData.data)
            socket.write(gcmData.data)

            sentSize += bodyLength
            requestCount++
            //Hilog.debug(0, "VmessProxyListener",
            //    "VMESS write done ${address} ${sentSize}, ${requestCount}, ${payload.size}")
        }
    }

    public func read(payload: Array<UInt8>): Int64 {
        //Hilog.debug(0, "VmessProxyListener", "VMESS read")
        if (!responseHeaderRead) {
            if (readResponseHeader() < 0) {
                return -1
            }
        }

        //Hilog.debug(0, "VmessProxyListener", "VMESS read payload")
        if (responseRemainingBuffer.size <= 0) {
            var lengthBuffer = Array<UInt8>(2, item: 0)
            let count = socket.read(lengthBuffer)
         //Hilog.debug(0, "VmessProxyListener", "VMESS read payload length ${lengthBuffer} ${count}")
            if (count != 2) {
                return -1
            }
            let length = UInt16.readBigEndian(lengthBuffer)
           //Hilog.debug(0, "VmessProxyListener", "VMESS read payload length 2 ${lengthBuffer} ${length}")
            let buffer = Array<UInt8>(Int64(length), item: 0)
            var readSize = 0
            while (readSize < buffer.size) {
                let count = socket.read(buffer.slice(readSize, buffer.size - readSize))
                readSize += count
            }
            //Hilog.debug(0, "VmessProxyListener", "VMESS read payload length 3 ${lengthBuffer} ${length} ${readSize}")

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
            //Hilog.debug(0, "VmessProxyListener",
            //    "VMESS read payload length 4 ${decryptedData.data.size} ${gcmData.data.size}")
            if (gcmData.data.size != 0) {
                return -1
            }

            responseRemainingBuffer = decryptedData.data
            responseCount++
        }
        //Hilog.debug(0, "VmessProxyListener",
        //    "VMESS read payload length eee ${responseRemainingBuffer.size} ${payload.size}")

        let copyLength = min(responseRemainingBuffer.size, payload.size)
        responseRemainingBuffer.copyTo(payload, 0, 0, copyLength)
        if (copyLength < responseRemainingBuffer.size) {
            responseRemainingBuffer = responseRemainingBuffer.slice(copyLength, responseRemainingBuffer.size - copyLength
            )
        } else {
            responseRemainingBuffer = Array<UInt8>()
        }
        //Hilog.debug(0, "VmessProxyListener", "VMESS read payload length 5 ${copyLength} ${responseRemainingBuffer.size}"
        //)
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
            if (destinationIP.size <= 0) {
                destinationIP = socket.destinationIP
            }
            vmess.setHeader(socket.protocol, destinationIP, socket.destinationPort)

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
