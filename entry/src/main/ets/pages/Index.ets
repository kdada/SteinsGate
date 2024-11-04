import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';
  private want: Want = {
    deviceId: "",
    bundleName: "com.kilodim.steinsgate",
    abilityName: "SteinsGateAbility",
  };

  build() {
    Row() {
      Column() {
        Button('Start VPN').onClick(() => {
          vpnExtension.startVpnExtensionAbility(this.want);
        }).width('70%').fontSize(20).margin(16)
        Button('Stop VPN').onClick(() => {
          vpnExtension.stopVpnExtensionAbility(this.want);
        }).width('70%').fontSize(20).margin(16)

      }.width('100%')
    }.height('100%')
  }
}
