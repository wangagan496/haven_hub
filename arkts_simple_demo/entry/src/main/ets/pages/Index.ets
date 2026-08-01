@Entry
@Component
struct Index {
  @State name: string = '';
  @State message: string = '请输入名字，然后点击按钮';
  @State clickCount: number = 0;

  private sayHello(): void {
    const displayName: string = this.name.trim();
    this.message = displayName.length > 0
      ? `你好，${displayName}！`
      : '你好，朋友！';
    this.clickCount += 1;
  }

  build() {
    Column({ space: 20 }) {
      Text('我的第一个 ArkTS 应用')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor('#182431')

      Text('VS Code 修改，DevEco Studio 运行')
        .fontSize(15)
        .fontColor('#667085')

      TextInput({
        placeholder: '请输入你的名字',
        text: this.name
      })
        .width('100%')
        .height(48)
        .backgroundColor(Color.White)
        .borderRadius(8)
        .onChange((value: string) => {
          this.name = value;
        })

      Button('打个招呼')
        .width('100%')
        .height(48)
        .fontSize(16)
        .backgroundColor('#1476E8')
        .onClick(() => {
          this.sayHello();
        })

      Text(this.message)
        .width('100%')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor('#182431')
        .textAlign(TextAlign.Center)
        .margin({ top: 12 })

      Text(`按钮已点击 ${this.clickCount} 次`)
        .fontSize(14)
        .fontColor('#667085')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: 28, right: 28 })
    .backgroundColor('#F5F7FA')
  }
}

