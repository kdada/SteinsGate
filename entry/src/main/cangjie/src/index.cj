package ohos_app_cangjie_entry

internal import ohos.ark_interop.JSModule
internal import ohos.ark_interop.JSContext
internal import ohos.ark_interop.JSCallInfo
internal import ohos.ark_interop.JSValue
internal import cj_res_entry.app
import ohos_app_cangjie_entry.vgate.*
import ohos.hilog.Hilog
import ohos.file_fs.*

var device: ?TunDevice = None

func startVpn(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    if (device.isSome()) {
        stopVpn(runtime, callInfo)
    }
    let tunFd = Int32(callInfo[0].toNumber())
    let configFilePath = callInfo[1].toString()
    let configData = FileFs.readText(configFilePath)

    Hilog.debug(0, "configData", configData)

    let domainList = ""
    let ipList = ""
    let domainBlackList = ""
    let ipBlackList = ""
    let directDNS = Array<UInt8>()
    let proxyDNS = Array<UInt8>()
    let server = ""
    let port: UInt16 = 0
    let id = ""
    let dnsProxyType = 0
    let ipProxyType = 0

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
