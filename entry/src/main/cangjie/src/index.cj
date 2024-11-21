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

var device: ?TunDevice = None

func startVpn(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    if (device.isSome()) {
        stopVpn(runtime, callInfo)
    }
    let tunFd = Int32(callInfo[0].toNumber())
    let configFilePath = callInfo[1].toString()
    let configJson = FileFs.readText(configFilePath)

    Hilog.debug(0, "configData", configJson)
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
    let port: UInt16 = UInt16(configValue.get("port").getOrThrow().asInt().getValue())
    let id = configValue.get("id").getOrThrow().asString().getValue()

    Hilog.debug(0, "startVpn", "domainListURL: ${domainListURL}")
    Hilog.debug(0, "startVpn", "ipListURL: ${ipListURL}")
    Hilog.debug(0, "startVpn", "downloadDomainListViaProxy: ${downloadDomainListViaProxy}")
    Hilog.debug(0, "startVpn", "downloadIPListViaProxy: ${downloadIPListViaProxy}")
    Hilog.debug(0, "startVpn", "domainBlackList: ${domainBlackList}")
    Hilog.debug(0, "startVpn", "ipBlackList: ${ipBlackList}")
    Hilog.debug(0, "startVpn", "directDNSString: ${directDNSString}")
    Hilog.debug(0, "startVpn", "proxyDNSString: ${proxyDNSString}")
    Hilog.debug(0, "startVpn", "dnsProxyType: ${dnsProxyType}")
    Hilog.debug(0, "startVpn", "ipProxyType: ${ipProxyType}")
    Hilog.debug(0, "startVpn", "serverIPOrDomain: ${serverIPOrDomain}")
    Hilog.debug(0, "startVpn", "port: ${port}")
    Hilog.debug(0, "startVpn", "id: ${id}")

    let serverAddress = SocketAddress.resolve(serverIPOrDomain, port)
    if (serverAddress.isNone()) {
        throw Exception("Invalid server address ${serverIPOrDomain}:${port}")
    }
    let server = serverAddress.getOrThrow().hostAddress

    let downloadFile = {
        url: String, proxy: Bool =>
        if (url == "") {
            return ""
        }
        let builder = ClientBuilder()
        if (downloadDomainListViaProxy) {
            let connector = {
                sa: SocketAddress =>
                let vmess = VmessConnection(id, server, port)
                vmess.connect()
                vmess.setHeader(ProtocolTcp, sa.address, sa.port)
                return vmess
            }
            builder.connector(connector)
        }
        let client = builder.build()
        let resp = client.get(domainListURL)
        var result = ""
        if (resp.bodySize.isSome()) {
            let size = resp.bodySize.getOrThrow()
            let buffer = Array<UInt8>(size, item: 0)
            resp.body.read(buffer)
            result = String.fromUtf8(buffer)
        }
        client.close()
        return result
    }

    var domainList = downloadFile(domainListURL, downloadDomainListViaProxy)
    var ipList = downloadFile(ipListURL, downloadIPListViaProxy)

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

    let pool = IPPacketPool(10000)
    let dev = TunDevice(tunFd, pool)

    let udpStack = UdpStack(dev, pool)
    let tcpStack = TcpStack(dev, pool)

    if (domainBlackList != "") {
        udpStack.register(
            CustomTunSocketHandler(
                InDomains(domainBlackList),
                BlackHoleListener()
            )
        )
    }

    if (ipBlackList != "") {
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
        udpStack.register(CustomTunSocketHandler(checker, VmessProxyListener(id, server, port).dnat(proxyDNS)))
    }
    udpStack.register(CustomTunSocketHandler(OnlyDNSRequest(), DnsDirectListener(directDNS)))

    if (ipList != "") {
        var checker: TunSocketChecker = All()
        if (dnsProxyType == 1) {
            checker = InAddresses(domainList)
        } else if (dnsProxyType == 2) {
            checker = Not(InAddresses(domainList))
        } else if (dnsProxyType == 3) {
            checker = All()
        } else {
            checker = Not(All())
        }
        udpStack.register(CustomTunSocketHandler(checker, VmessProxyListener(id, server, port)))
        tcpStack.register(CustomTunSocketHandler(checker, VmessProxyListener(id, server, port)))
    }
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
