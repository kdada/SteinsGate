import { VMessAuthData } from "./Base"

@ComponentV2
export struct Detail {
  @Param item: VMessAuthData = new VMessAuthData()
  @Event changeAlias: (str: string) => void = () => {
  }

  build() {
    NavDestination() {
      Column() {
        Row() {
          Text("别名")
            .width("30%")
            .textAlign(TextAlign.Start)
          TextInput({ text: this.item.alias })
            .width("60%")
            .textAlign(TextAlign.End)
            .type(InputType.Normal)
            .maxLength(200)
            .onChange((str) => {
              this.changeAlias(str)
            })
        }
        .height(40)
        .alignItems(VerticalAlign.Center)

        Row() {
          Text("地址")
            .width("30%")
            .textAlign(TextAlign.Start)
          Text(this.item.address)
            .width("60%")
            .textAlign(TextAlign.End)
        }
        .height(40)
        .alignItems(VerticalAlign.Center)

        Row() {
          Text("端口")
            .width("30%")
            .textAlign(TextAlign.Start)
          Text(this.item.port)
            .width("60%")
            .textAlign(TextAlign.End)
        }
        .height(40)
        .alignItems(VerticalAlign.Center)

        Row() {
          Text("ID")
            .width("30%")
            .textAlign(TextAlign.Start)
          Text(this.item.id)
            .width("60%")
            .textAlign(TextAlign.End)
        }
        .height(40)
        .alignItems(VerticalAlign.Center)
      }
    }
    .title("详情")
  }
}