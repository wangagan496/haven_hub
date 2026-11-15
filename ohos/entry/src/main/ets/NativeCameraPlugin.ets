import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler,
  MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { deviceInfo } from '@kit.BasicServicesKit';

/** One request owns the native page; no system application impersonation. */
export class NativeCameraRequest {
  private static pending: MethodResult | null = null;
  private static serial: number = 0;
  static quality: number = 90;

  static open(result: MethodResult, quality: number): void {
    if (NativeCameraRequest.pending !== null) {
      result.error('already_active', 'Camera is already active', null);
      return;
    }
    NativeCameraRequest.pending = result;
    NativeCameraRequest.serial++;
    NativeCameraRequest.quality = quality;
    AppStorage.setOrCreate('havenNativeCameraCancel', false);
    AppStorage.setOrCreate('havenNativeCamera', true);
  }

  static get id(): number { return NativeCameraRequest.serial; }

  static complete(id: number, path: string | null, error?: string): void {
    if (id !== NativeCameraRequest.serial) return;
    const result = NativeCameraRequest.pending;
    NativeCameraRequest.pending = null;
    AppStorage.setOrCreate('havenNativeCamera', false);
    if (error) result?.error(error, 'Native camera unavailable', null);
    else result?.success(path);
  }

  static cancel(): void {
    if (NativeCameraRequest.pending !== null) {
      AppStorage.setOrCreate('havenNativeCameraCancel', true);
    }
  }
}

export default class NativeCameraPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  getUniqueClassName(): string { return 'NativeCameraPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'haven_hub/native_camera');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    NativeCameraRequest.cancel();
    NativeCameraRequest.complete(NativeCameraRequest.id, null, 'camera_unavailable');
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'capture') { result.notImplemented(); return; }
    // This fallback is verified for the emulator's missing system camera.
    if (deviceInfo.productModel !== 'emulator') {
      result.error('camera_unavailable', 'System camera unavailable', null);
      return;
    }
    const quality = call.argument('imageQuality') as number;
    if (!Number.isFinite(quality) || quality < 0 || quality > 100) {
      result.error('camera_capture_failed', 'Invalid image quality', null);
      return;
    }
    NativeCameraRequest.open(result, quality);
  }
}
