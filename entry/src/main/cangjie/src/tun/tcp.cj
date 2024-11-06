/**
 * Created on 2024/11/5
 */
package ohos_app_cangjie_entry.tun

import ohos.hilog.Hilog

extend IPPacket {
    func tcpSrcPort(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset]) << 8) + UInt16(data[headerOffset + 1])
    }

    @OverflowWrapping
    func setTcpSrcPort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset] = UInt8(port >> 8)
        data[headerOffset + 1] = UInt8(port)
    }

    func tcpDestPort(): UInt16 {
        let headerOffset = headerLength()
        return (UInt16(data[headerOffset + 2]) << 8) + UInt16(data[headerOffset + 3])
    }

    @OverflowWrapping
    func setTcpDestPort(port: UInt16) {
        let headerOffset = headerLength()
        data[headerOffset + 2] = UInt8(port >> 8)
        data[headerOffset + 3] = UInt8(port)
    }

    @OverflowWrapping
    func resumTcp() {
        let headerOffset = headerLength()
        data[headerOffset + 16] = 0
        data[headerOffset + 17] = 0
        let result = sumWithPseudoIPHeader(payload())
        data[headerOffset + 16] = UInt8(result >> 8)
        data[headerOffset + 17] = UInt8(result)
    }
}

public class TcpStack <: IPProtocolStack {
    public override func protocol(): UInt8 {
        return 0x6
    }

    public override func pop(packet: IPPacket) {
        //Hilog.debug(0, "debugTun",
        //    "TCP: Size: ${packet.length()} From ${packet.srcIPString()} To ${packet.destIPString()}")
        packet.release()
    }
}
