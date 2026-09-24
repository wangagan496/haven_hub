import { AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding, WindowFocusChangedListener,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';

/** App-local bridge. No account data or remote URL crosses this channel. */
export default class VisitorPassSharePlugin implements FlutterPlugin, AbilityAware, MethodCallHandler,
  WindowFocusChangedListener {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;
  private controller: systemShare.ShareController | null = null;
  private pending: MethodResult | null = null;
  private abilityBinding: AbilityPluginBinding | null = null;
  private focused: boolean = true;
  private readonly onDismiss: () => void = () => { this.finish(); };

  getUniqueClassName(): string { return 'VisitorPassSharePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'haven_hub/visitor_pass_share');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.onDetachedFromAbility();
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.context = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityBinding = binding;
    this.focused = true;
    this.context = binding.getAbility().context;
    binding.addOnWindowFocusChangedListener(this);
  }

  onDetachedFromAbility(): void {
    this.abilityBinding?.removeOnWindowFocusChangedListener(this);
    this.abilityBinding = null;
    this.context = null;
    this.finish('unavailable');
  }

  onWindowFocusChanged(hasFocus: boolean): void {
    this.focused = hasFocus;
    // Opening the system panel also loses focus: only cancel preparation.
    if (!hasFocus && this.controller === null) this.finish('unavailable');
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'shareImage') {
      result.notImplemented();
      return;
    }
    if (this.pending !== null) {
      result.error('busy', 'A share is already active', null);
      return;
    }
    const context = this.context;
    if (context === null || !this.focused) {
      result.error('unavailable', 'No attached UIAbility', null);
      return;
    }
    const bytes = call.argument('bytes') as Uint8Array;
    if (!(bytes instanceof Uint8Array) || bytes.length < 8 || bytes.length > 5 * 1024 * 1024) {
      result.error('invalid_image', 'Invalid image bytes', null);
      return;
    }
    const png = bytes[0] === 137 && bytes[1] === 80 && bytes[2] === 78 && bytes[3] === 71 &&
      bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10;
    const jpeg = bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
    if (!png && !jpeg) {
      result.error('invalid_image', 'Only PNG and JPEG are supported', null);
      return;
    }
    let anchor: systemShare.ShareControllerAnchor | undefined;
    if (call.hasArgument('anchorX')) {
      const x = call.argument('anchorX') as number;
      const y = call.argument('anchorY') as number;
      const width = call.argument('anchorWidth') as number;
      const height = call.argument('anchorHeight') as number;
      if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(width) ||
        !Number.isFinite(height) || width <= 0 || height <= 0) {
        result.error('invalid_anchor', 'Invalid window pixel coordinates', null);
        return;
      }
      anchor = { windowOffset: { x: x, y: y }, size: { width: width, height: height } };
    }
    this.pending = result;
    this.openShare(context, bytes, png, result, anchor);
  }

  private async openShare(context: common.UIAbilityContext, bytes: Uint8Array,
    png: boolean, result: MethodResult, anchor?: systemShare.ShareControllerAnchor): Promise<void> {
    let path = '';
    try {
      const source = image.createImageSource(bytes.buffer);
      try {
        const info = await source.getImageInfo();
        if (info.size.width <= 0 || info.size.height <= 0 ||
          info.size.width * info.size.height > 16000000) {
          throw new Error('Invalid image dimensions');
        }
      } finally {
        await source.release();
      }
      if (this.pending !== result || this.context !== context) return;
      const directory = `${context.cacheDir}/visitor-pass-share`;
      if (!fs.accessSync(directory)) fs.mkdirSync(directory);
      await this.cleanOldFiles(directory);
      path = `${directory}/pass-${Date.now()}.${png ? 'png' : 'jpg'}`;
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        const written = await fs.write(file.fd, bytes.buffer);
        if (written !== bytes.byteLength) throw new Error('Incomplete image write');
      } finally {
        await fs.close(file);
      }
      if (this.pending !== result || this.context !== context || !this.focused) {
        await fs.unlink(path);
        return;
      }
      const data = new systemShare.SharedData({
        utd: png ? uniformTypeDescriptor.UniformDataType.PNG : uniformTypeDescriptor.UniformDataType.JPEG,
        uri: fileUri.getUriFromPath(path),
        title: '访客通行码'
      });
      const controller = new systemShare.ShareController(data);
      this.controller = controller;
      controller.on('dismiss', this.onDismiss);
      const options: systemShare.ShareControllerOptions = {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      };
      if (anchor !== undefined) options.anchor = anchor;
      await controller.show(context, options);
      // show() only opens the panel. Resolve on dismiss, without claiming delivery.
      // Keep the file after dismissal so the receiving app can still read it.
    } catch (_) {
      if (this.pending === result) this.finish('share_failed');
      if (path.length > 0) {
        try { await fs.unlink(path); } catch (_) { /* Already removed. */ }
      }
    }
  }

  private finish(errorCode?: string): void {
    const result = this.pending;
    this.pending = null;
    const controller = this.controller;
    this.controller = null;
    if (controller !== null) {
      try { controller.off('dismiss', this.onDismiss); } catch (_) { /* Detaching. */ }
    }
    if (errorCode !== undefined) result?.error(errorCode, 'System share unavailable', null);
    else result?.success(null);
  }

  private async cleanOldFiles(directory: string): Promise<void> {
    // Only our own cache files, older than 24 hours. Never delete on panel dismissal.
    let names: string[];
    try {
      names = await fs.listFile(directory);
    } catch (_) {
      // Expired-cache cleanup is best effort and must not block a new share.
      return;
    }
    for (const name of names) {
      if (!/^pass-\d+\.(png|jpg)$/.test(name)) continue;
      const timestamp = Number(name.substring(5, name.lastIndexOf('.')));
      if (Date.now() - timestamp > 24 * 60 * 60 * 1000) {
        try { await fs.unlink(`${directory}/${name}`); } catch (_) { /* Best effort. */ }
      }
    }
  }
}
