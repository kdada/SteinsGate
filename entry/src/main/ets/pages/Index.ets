import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { ComponentContent, SymbolGlyphModifier } from '@kit.ArkUI';
import { Setting } from './Setting';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { VMessAuthData } from './Base';
import { Detail } from './Detail';

class PromptParams<T> {
  private ctx?: UIContext
  private content?: ComponentContent<PromptParams<T>>
  public data: T

  constructor(ctx: UIContext, builder: WrappedBuilder<[PromptParams<T>]>, data: T) {
    this.ctx = ctx
    this.content = new ComponentContent(this.ctx, builder, this);
    this.data = data
  }

  open() {
    this.ctx?.getPromptAction().openCustomDialog(this.content, new Object(this))
  }

  close() {
    this.ctx?.getPromptAction().closeCustomDialog(this.content)
  }
}

class VMessParams {
  public data: string = ""
  public index?: Index

  constructor(index: Index) {
    this.index = index
  }
}

@Builder
function buildVMessInput(params: PromptParams<VMessParams>) {
  Row() {
    Column() {
      Text("输入 VMess 链接")
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
      Text("仅支持 TCP 模式且服务端关闭强制 AEAD 认证")
        .fontSize(12)
        .fontWeight(FontWeight.Normal)
        .margin({ bottom: 20 })
      TextArea({ placeholder: "vmess://base64EncodingData" })
        .margin({ bottom: 20 })
        .height(50)
        .onChange((value) => {
          params.data.data = value
        })
      Row() {
        Button('取消').onClick(() => {
          params.close()
        })
        Button('确认').onClick(() => {
          params.data.index?.addVMessItem(params.data.data)
          params.close()
        })
      }.width("50%")
      .justifyContent(FlexAlign.SpaceEvenly)
    }
    .backgroundColor("#F0F0F0")
    .padding(10)
    .border({ radius: 5 })
  }
  .alignItems(VerticalAlign.Center)
  .width("90%")
}

@Entry
@Component
struct Index {
  @State items: VMessAuthData[] = [];
  @Provide("pageStack") pageStack: NavPathStack = new NavPathStack();
  private next: number = 0
  private want: Want = {
    deviceId: "",
    bundleName: "com.kilodim.steinsgate",
    abilityName: "SteinsGateAbility",
  };

  @Builder
  pagesMap(name: string, param: object) {
    if (name == 'Setting') {
      Setting()
    } else if (name == 'Detail') {
      Detail({item: param as VMessAuthData})
    }
  }

  @Builder
  deleteButton(idx: number) {
    Button() {
      SymbolGlyph($r("sys.symbol.trash"))
        .fontSize(35)
    }
    .backgroundColor("#FF0000")
    .type(ButtonType.Normal)
    .width(60)
    .height("100%")
    .onClick((event) => {
      let item: VMessAuthData | undefined = undefined
      let index = 0
      for (let i = 0; i < this.items.length; i++) {
        if (idx == this.items[i].index) {
          item = this.items[i]
          index = i
          break
        }
      }
      if (!item) {
        return
      }
      this.items.splice(index, 1)
    })
  }

  build() {
    Column() {
      Navigation(this.pageStack) {
        RelativeContainer() {
          List() {
            ForEach(this.items, (item: VMessAuthData) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(item.alias)
                      .fontSize(15)
                      .fontWeight(FontWeight.Bold)
                    Text(item.address + ":" + item.port)
                      .fontSize(10)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .width("90%")
                  .margin({left: "5%"})
                }
                .margin(10)
                .width("100%")
                .onClick(() => this.pageStack.pushPathByName("Detail", item))
              }
              .swipeAction({ end: this.deleteButton(item.index) })
              .borderColor("#F0F0F0")
              .borderWidth({ bottom: 1 })
            }, (item: VMessAuthData, index: number) => `${item.index}`)
          }
          .alignRules({
            "top": { "anchor": "__container__", "align": VerticalAlign.Top },
            "left": { "anchor": "__container__", "align": HorizontalAlign.Start },
            "right": { "anchor": "__container__", "align": HorizontalAlign.End },
            "bottom": { "anchor": "__container__", "align": VerticalAlign.Bottom },
          })

          Row() {
            Column() {
              Button('Start VPN').onClick(() => {
                vpnExtension.startVpnExtensionAbility(this.want);
              }).width('70%').fontSize(20).margin(16)
              Button('Stop VPN').onClick(() => {
                vpnExtension.stopVpnExtensionAbility(this.want);
              }).width('70%').fontSize(20).margin(16)

            }.width('100%')
          }
          .alignRules({
            "right": { "anchor": "__container__", "align": HorizontalAlign.End },
            "bottom": { "anchor": "__container__", "align": VerticalAlign.Bottom },
          })
          .width(200)
          .height(200)
        }
      }
      .navDestination(this.pagesMap)
      .menus([
        {
          value: "add",
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.plus')),
          action: () => this.onAddButtonPressed()
        },
        {
          value: "scan",
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.line_viewfinder')),
          action: () => this.onScanButtonPressed()
        },
        {
          value: "setting",
          symbolIcon: new SymbolGlyphModifier($r('sys.symbol.gearshape')),
          action: () => this.pageStack.pushPathByName("Setting", undefined)
        },
      ])
      .title($r("app.string.EntryAbility_label"))
      .titleMode(NavigationTitleMode.Mini)
      .hideBackButton(true)
      .mode(NavigationMode.Auto)
    }
  }

  addVMessItem(data: string) {
    let protocolHeader = "vmess://"
    if (!data.startsWith(protocolHeader)) {
      this.getUIContext().getPromptAction().showToast({
        message: `协议连接必须以 vmess:// 开头`
      })
      return
    }
    try {
      let body = data.slice(protocolHeader.length)
      let base64 = new util.Base64Helper()
      let decodedData = base64.decodeSync(body)
      let decoder = new util.TextDecoder()
      let vmessData = decoder.decodeToString(decodedData)
      let vmessObject = JSON.parse(vmessData) as Record<string, string>
      let version = vmessObject["v"]
      if (version != "2") {
        this.getUIContext().getPromptAction().showToast({
          message: `仅支持 v2 版本的链接配置，当前版本为 ${version}`
        })
        return
      }

      let alias = vmessObject["ps"]
      let ipOrDomain = vmessObject["add"]
      let port = vmessObject["port"]
      let id = vmessObject["id"]
      let alterId = vmessObject["aid"]
      let net = vmessObject["net"]

      if (alterId != "0") {
        this.getUIContext().getPromptAction().showToast({
          message: `仅支持 alterId 为 0 的 VMess 配置，当前 alterId 为 ${alterId}`
        })
        return
      }
      if (net != "tcp") {
        this.getUIContext().getPromptAction().showToast({
          message: `仅支持通过 TCP 连接 vmess 服务器，当前配置为 ${net}`
        })
        return
      }
      let authdata: VMessAuthData = {
        index: this.next++,
        alias: alias,
        address: ipOrDomain,
        port: port,
        id: id,
      }
      this.items.push(authdata)
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({
        message: `无法解析 vmess 链接内容，请确认链接内容是否为 JSON`
      })
    }
  }

  onAddButtonPressed() {
    let params = new PromptParams(this.getUIContext(), wrapBuilder(buildVMessInput), new VMessParams(this))
    params.open()
  }

  onScanButtonPressed() {
    let options: scanBarcode.ScanOptions =
      { scanTypes: [scanCore.ScanType.ALL], enableMultiMode: true, enableAlbum: true };
    try {
      scanBarcode.startScanForResult(getContext(this), options).then((result: scanBarcode.ScanResult) => {
        this.addVMessItem(result.originalValue)
      });
    } catch (error) {
    }
  }
}
