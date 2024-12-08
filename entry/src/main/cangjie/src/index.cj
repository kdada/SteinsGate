package ohos_app_cangjie_entry

internal import ohos.ark_interop.JSModule
internal import ohos.ark_interop.JSContext
internal import ohos.ark_interop.JSCallInfo
internal import ohos.ark_interop.JSValue
internal import cj_res_entry.app
import ohos_app_cangjie_entry.vgate.*
import ohos.hilog.Hilog
import ohos.file_fs.*
import encoding.json.*
import serialization.serialization.*
import std.convert.*
import net.http.*
import std.socket.*
import net.tls.TlsClientConfig
import net.tls.CertificateVerifyMode
import encoding.url.URL

var device: ?TunDevice = None

func startVpn(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    if (device.isSome()) {
        stopVpn(runtime, callInfo)
    }
    let tunFd = Int32(callInfo[0].toNumber())
    let configFilePath = callInfo[1].toString()
    let configJson = FileFs.readText(configFilePath)

    Hilog.debug(0x1799, "configData", configJson)
    let configValue = JsonValue.fromStr(configJson).asObject()

    let domainListURL = configValue.get("domainListURL").getOrThrow().asString().getValue()
    let ipListURL = configValue.get("ipListURL").getOrThrow().asString().getValue()
    let downloadDomainListViaProxy = configValue.get("downloadDomainListViaProxy").getOrThrow().asBool().getValue()
    let downloadIPListViaProxy = configValue.get("downloadIPListViaProxy").getOrThrow().asBool().getValue()

    let domainBlackList = configValue.get("domainBlackList").getOrThrow().asString().getValue()
    let ipBlackList = configValue.get("ipBlackList").getOrThrow().asString().getValue()
    let directDNSString = configValue.get("directDNS").getOrThrow().asString().getValue()
    let proxyDNSString = configValue.get("proxyDNS").getOrThrow().asString().getValue()
    let dnsProxyType = configValue.get("dnsProxyType").getOrThrow().asInt().getValue()
    let ipProxyType = configValue.get("ipProxyType").getOrThrow().asInt().getValue()

    let serverIPOrDomain = configValue.get("server").getOrThrow().asString().getValue()
    let serverPort = configValue.get("port").getOrThrow().asString().getValue()

    let port = UInt16.parse(serverPort)
    let id = configValue.get("id").getOrThrow().asString().getValue()

    Hilog.debug(0x1799, "startVpn", "domainListURL: ${domainListURL}")
    Hilog.debug(0x1799, "startVpn", "ipListURL: ${ipListURL}")
    Hilog.debug(0x1799, "startVpn", "downloadDomainListViaProxy: ${downloadDomainListViaProxy}")
    Hilog.debug(0x1799, "startVpn", "downloadIPListViaProxy: ${downloadIPListViaProxy}")
    Hilog.debug(0x1799, "startVpn", "domainBlackList: ${domainBlackList}")
    Hilog.debug(0x1799, "startVpn", "ipBlackList: ${ipBlackList}")
    Hilog.debug(0x1799, "startVpn", "directDNSString: ${directDNSString}")
    Hilog.debug(0x1799, "startVpn", "proxyDNSString: ${proxyDNSString}")
    Hilog.debug(0x1799, "startVpn", "dnsProxyType: ${dnsProxyType}")
    Hilog.debug(0x1799, "startVpn", "ipProxyType: ${ipProxyType}")
    Hilog.debug(0x1799, "startVpn", "serverIPOrDomain: ${serverIPOrDomain}")
    Hilog.debug(0x1799, "startVpn", "port: ${port}")
    Hilog.debug(0x1799, "startVpn", "id: ${id}")

    let serverAddress = SocketAddress.resolve(serverIPOrDomain, port)
    if (serverAddress.isNone()) {
        throw Exception("Invalid server address ${serverIPOrDomain}:${port}")
    }
    let server = serverAddress.getOrThrow().hostAddress
    Hilog.debug(0x1799, "startVpn", "serverIP: ${server}")

    let downloadFile = {
        downloadURL: String, proxy: Bool =>
        if (downloadURL == "") {
            return ""
        }

        let url = URL.parse(downloadURL)
        let builder = ClientBuilder()
        var tlsConfig = TlsClientConfig()
        tlsConfig.verifyMode = CertificateVerifyMode.TrustAll
        builder.tlsConfig(tlsConfig)
        if (proxy) {
            let connector = {
                sa: SocketAddress =>
                Hilog.debug(0x1799, "startVpn", "download from: ${url.hostName} ${sa.address} ${sa.port}")
                let vmess = VmessConnection(id, server, port)
                vmess.connect()
                vmess.setHeaderWithDomain(ProtocolTcp, url.hostName, sa.port)
                return vmess
            }
            builder.connector(connector)
        }
        let client = builder.build()
        let resp = client.get(downloadURL)
        var result = ""
        if (resp.bodySize.isSome()) {
            let size = resp.bodySize.getOrThrow()
            let buffer = Array<UInt8>(size, item: 0)
            var readCount = 0
            while (readCount < size) {
                let count = resp.body.read(buffer.slice(readCount, size - readCount))
                readCount += count
            }
            result = String.fromUtf8(buffer)
        }
        client.close()
        return result
    }

    var domainList = downloadFile(domainListURL, downloadDomainListViaProxy)
    var ipList = downloadFile(ipListURL, downloadIPListViaProxy)
    Hilog.debug(0x1799, "startVpn", "download files: ${domainList.size} ${ipList.size}")

    let convertDNS = {
        dns: String =>
        let parts = dns.split(".", removeEmpty: true)
        let result = Array<UInt8>(4, item: 0)
        if (parts.size != 4) {
            throw Exception("Invalid dns server ${dns}")
        }
        for (i in 0..4) {
            result[i] = UInt8.parse(parts[i])
        }
        return result
    }

    let directDNS = convertDNS(directDNSString)
    let proxyDNS = convertDNS(proxyDNSString)
    Hilog.debug(0x1799, "startVpn", "dns: ${directDNS} ${proxyDNS}")

    let pool = IPPacketPool(10000)
    let dev = TunDevice(tunFd, pool)

    let udpStack = UdpStack(dev, pool)
    let tcpStack = TcpStack(dev, pool)

    if (domainBlackList != "") {
        Hilog.debug(0x1799, "startVpn", "add InDomains BlackHoleListener")
        udpStack.register(
            CustomTunSocketHandler(
                InDomains(domainBlackList),
                BlackHoleListener()
            )
        )
    }

    if (ipBlackList != "") {
        Hilog.debug(0x1799, "startVpn", "add InAddresses BlackHoleListener")
        let handler = CustomTunSocketHandler(
            InAddresses(ipBlackList),
            BlackHoleListener()
        )
        udpStack.register(handler)
        tcpStack.register(handler)
    }

    if (domainList != "") {
        var checker: TunSocketChecker = OnlyDNSRequest()
        if (dnsProxyType == 1) {
            checker = InDomains(domainList)
        } else if (dnsProxyType == 2) {
            checker = Not(InDomains(domainList))
        } else if (dnsProxyType == 3) {
            checker = OnlyDNSRequest()
        } else {
            checker = Not(All())
        }
        Hilog.debug(0x1799, "startVpn", "add domainList VmessProxyListener")
        udpStack.register(CustomTunSocketHandler(checker, VmessProxyListener(id, server, port).dnat(proxyDNS)))
    }
    Hilog.debug(0x1799, "startVpn", "add OnlyDNSRequest DnsDirectListener")
    udpStack.register(CustomTunSocketHandler(OnlyDNSRequest(), DnsDirectListener(directDNS)))

    if (ipList != "") {
        var checker: TunSocketChecker = All()
        if (ipProxyType == 1) {
            checker = InAddresses(ipList)
        } else if (ipProxyType == 2) {
            checker = Not(InAddresses(ipList))
        } else if (ipProxyType == 3) {
            checker = All()
        } else {
            checker = Not(All())
        }
        Hilog.debug(0x1799, "startVpn", "add ipList VmessProxyListener")
        udpStack.register(CustomTunSocketHandler(checker, VmessProxyListener(id, server, port)))
        tcpStack.register(CustomTunSocketHandler(checker, VmessProxyListener(id, server, port)))
    }
    Hilog.debug(0x1799, "startVpn", "add All DirectListener")
    udpStack.register(CustomTunSocketHandler(All(), UdpDirectListener()))
    tcpStack.register(CustomTunSocketHandler(All(), TcpDirectListener()))

    dev.register(udpStack)
    dev.register(tcpStack)
    dev.start()
    device = dev
    return runtime.undefined().toJSValue()
}

func stopVpn(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    spawn {
        device?.close()
    }
    device = None
    return runtime.undefined().toJSValue()
}

let EXPORT_MODULE = JSModule.registerModule {
    runtime, exports =>
    exports["startVpn"] = runtime.function(startVpn).toJSValue()
    exports["stopVpn"] = runtime.function(stopVpn).toJSValue()
}
