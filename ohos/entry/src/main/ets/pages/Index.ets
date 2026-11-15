
import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos'
import { NativeCameraPage } from './NativeCameraPage';
import { NativeCameraRequest } from '../NativeCameraPlugin';

const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Entry({ useSharedStorage: true })
@Component
struct Index {
  @StorageLink('havenNativeCamera') cameraActive: boolean = false;
  @LocalStorageLink('viewId') viewId: string = "";

  build() {
    Stack() {
      FlutterPage({ viewId: this.viewId })
        .accessibilityLevel(this.cameraActive ? 'no-hide-descendants' : 'auto')
      if (this.cameraActive) {
        NativeCameraPage()
      }
    }
  }

  onBackPress(): boolean {
    if (this.cameraActive) {
      NativeCameraRequest.cancel();
      return true;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (context === undefined) return false;
    context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}
