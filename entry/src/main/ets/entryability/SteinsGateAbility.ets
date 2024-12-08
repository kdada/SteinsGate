import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { requireCJLib } from "libark_interop_loader.so";

interface CJLib {
  startVpn(src: number, configPath: string): number
  stopVpn(): number
}

const cjlib = requireCJLib("libohos_app_cangjie_entry.so") as CJLib

export default class SteinsGateAbility extends VpnExtensionAbility {
  private tunIp: string = '172.19.0.1';
  private blockedAppName: string = 'com.kilodim.steinsgate';
  private vpnConnection?: vpnExtension.VpnConnection;
  private connFd = -1;
  private tunFd: number = -1;

  async onCreate(want: Want): Promise<void> {
    this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    hilog.info(0x1799, 'debugVPN', '%{public}s', 'Succeeded to create vpn connection');
    await this.SetupVpn();
    let configPath = this.context.filesDir + "/config.json"
    hilog.info(0x1799, 'debugVPN', `Start vpn with config ${configPath}`);
    try {
      cjlib.startVpn(this.tunFd, configPath);
    } catch (e) {
      hilog.info(0x1799, 'debugVPN', `Failed to start vpn ${e}`);
    }
    hilog.info(0x1799, 'debugVPN', `Succeeded to connect server`);
    //await this.Protect();
  }



  async Protect(): Promise<void> {
    try {
      await this.vpnConnection!.protect(this.connFd)
      hilog.info(0x1799, 'debugVPN', `Succeeded to protect fd: ${this.connFd}`);
    } catch (error) {
      hilog.error(0x1799, 'debugVPN', 'vpn protect fail: %{public}s', JSON.stringify(error) ?? '');
    }
  }

  async SetupVpn() {
    class Address {
      address: string;
      family: number;

      constructor(address: string, family: number) {
        this.address = address;
        this.family = family;
      }
    }

    class AddressWithPrefix {
      address: Address;
      prefixLength: number;

      constructor(address: Address, prefixLength: number) {
        this.address = address;
        this.prefixLength = prefixLength;
      }
    }

    class Config {
      addresses: AddressWithPrefix[];
      mtu: number;
      dnsAddresses: string[];
      trustedApplications: string[];
      blockedApplications: string[];

      constructor(
        tunIp: string,
        blockedAppName: string
      ) {
        this.addresses = [
          new AddressWithPrefix(new Address(tunIp, 1), 24)
        ];
        this.mtu = 1400;
        this.dnsAddresses = ["172.19.0.2"];
        this.trustedApplications = [];
        this.blockedApplications = [blockedAppName];
      }
    }

    let config = new Config(this.tunIp, this.blockedAppName);

    try {
      this.tunFd = await this.vpnConnection!.create(config);
      hilog.info(0x1799, 'debugVPN', `Succeeded to create vpn: ${this.tunFd}`);
    } catch (error) {
      hilog.error(0x1799, 'debugVPN', 'vpn set up fail: %{public}s', JSON.stringify(error) ?? '');
    }
  }

  async onDestroy(): Promise<void> {
    cjlib.stopVpn()
    hilog.info(0x1799, 'debugVPN', `Succeeded to disconnect server`);
    try {
      await this.vpnConnection?.destroy()
      hilog.info(0x1799, 'debugVPN', `Succeeded to destroy vpn: ${this.tunFd}`);
    } catch (error) {
      hilog.error(0x1799, 'debugVPN', 'vpn destroy fail: %{public}s', JSON.stringify(error) ?? '');
    }
  }
}