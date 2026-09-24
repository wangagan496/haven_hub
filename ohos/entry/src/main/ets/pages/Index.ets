
import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos'

const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Entry({ useSharedStorage: true })
@Component
struct Index {
  @LocalStorageLink('viewId') viewId: string = "";

  build() {
    Column() {
      FlutterPage({ viewId: this.viewId })
    }
  }

  onBackPress(): boolean {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) return false;
    context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}