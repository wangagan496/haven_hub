
import { deviceInfo } from '@kit.BasicServicesKit';
import { FlutterAbility, FlutterEngine, Log } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import VisitorPassSharePlugin from '../VisitorPassSharePlugin';

const TAG = 'EntryAbility';

export default class EntryAbility extends FlutterAbility {
  // On the Windows emulator, rebuilding the surface after the engine's
  // background GpuReclaim teardown intermittently fails in the host GL layer
  // (host qemu.log: get_host_texture_id fails, then GL error 502 for every
  // draw), leaving the page black after returning from Settings or Home.
  // Reporting the engine as PiP-visible while hidden makes it cancel the
  // deferred teardown. Real devices keep the default reclaim behavior.
  private readonly keepGpuResourcesInBackground: boolean = deviceInfo.productModel === 'emulator';

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new VisitorPassSharePlugin());
  }

  onBackground() {
    super.onBackground();
    this.setKeepGpuResources(true);
  }

  onForeground() {
    super.onForeground();
    this.setKeepGpuResources(false);
  }

  private setKeepGpuResources(keep: boolean) {
    if (!this.keepGpuResourcesInBackground) {
      return;
    }
    // The engine checks this flag when the deferred (1000ms) reclaim fires.
    this.getFlutterEngine()?.getFlutterNapi()?.setPipVisible(keep);
    Log.i(TAG, `emulator keep GPU resources in background: ${keep}`);
  }
}
