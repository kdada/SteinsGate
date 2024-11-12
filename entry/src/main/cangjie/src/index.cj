package ohos_app_cangjie_entry

internal import ohos.ark_interop.JSModule
internal import ohos.ark_interop.JSContext
internal import ohos.ark_interop.JSCallInfo
internal import ohos.ark_interop.JSValue
internal import cj_res_entry.app
import ohos_app_cangjie_entry.tun.*
import std.socket.TcpSocket

var device: ?TunDevice = None

func startVpn(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    if (device.isSome()) {
        stopVpn(runtime, callInfo)
    }
    let id = "b831381d-6324-4d53-ad4f-8cda48b30811"
    let server = "192.168.1.99"
    let port = UInt16(15867)

    let tunFd = Int32(callInfo[0].toNumber())
    let pool = IPPacketPool(10000)
    let dev = TunDevice(tunFd, pool)

    let udpStack = UdpStack(dev, pool)
    udpStack.register(CustomTunSocketHandler(InDomains("baidu.com"), VmessProxyListener(id, server, port).dnat([114, 114, 114, 114])))
    udpStack.register(CustomTunSocketHandler(OnlyDNSRequest(), DnsDirectListener([114, 114, 114, 114])))
    udpStack.register(CustomTunSocketHandler(All(), UdpDirectListener()))
    dev.register(udpStack)

    let tcpStack = TcpStack(dev, pool)
    tcpStack.register(CustomTunSocketHandler(InAddresses("180.101.50.0/24"), VmessProxyListener(id, server, port)))
    tcpStack.register(CustomTunSocketHandler(All(), TcpDirectListener()))
    dev.register(tcpStack)

    dev.start()
    device = dev
    return runtime.undefined().toJSValue()
}

func stopVpn(runtime: JSContext, callInfo: JSCallInfo): JSValue {
    device?.stop()
    device = None
    return runtime.undefined().toJSValue()
}

let EXPORT_MODULE = JSModule.registerModule {
    runtime, exports =>
    exports["startVpn"] = runtime.function(startVpn).toJSValue()
    exports["stopVpn"] = runtime.function(stopVpn).toJSValue()
}
