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
    let tunFd = Int32(callInfo[0].toNumber())
    let pool = IPPacketPool(1000)
    let dev = TunDevice(tunFd, pool)

    let udpStack = UdpStack(dev, pool)
    udpStack.register(DnsHandler([114, 114, 114, 114]))
    udpStack.register(UdpDirectHandler())
    dev.register(udpStack)

    let tcpStack = TcpStack(dev, pool)
    tcpStack.register(TcpDirectHandler())
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
