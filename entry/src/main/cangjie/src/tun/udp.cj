/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import ohos.hilog.Hilog

public class UdpStack <: IPProtocolStack {
    public override func protocol(): UInt8 {
        return 0x11
    }

    public override func pop(packet: IPPacket): Bool {
        Hilog.debug(0, "debugTun",
            "UDP: Size: ${packet.length()} From ${packet.srcIPString()} To ${packet.destIPString()}")
        packet.release()
        return true
    }
}
