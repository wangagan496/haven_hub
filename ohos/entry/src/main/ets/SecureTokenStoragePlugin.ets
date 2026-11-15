import { FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler,
  MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

const EMPTY_SESSION: string = '{"version":1,"token":"","refreshToken":""}';

/** Only SECRET is encrypted: the fixed alias contains no user information. */
export default class SecureTokenStoragePlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private busy: boolean = false;
  private generation: number = 0;

  getUniqueClassName(): string { return 'SecureTokenStoragePlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'haven_hub/secure_tokens');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.generation++;
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method !== 'read' && call.method !== 'write' && call.method !== 'clear') {
      result.notImplemented();
      return;
    }
    this.execute(call, result);
  }

  private alias(): Uint8Array {
    return new util.TextEncoder().encodeInto('haven_hub.session.v1');
  }

  private attributes(payload: Uint8Array, conflict: asset.ConflictResolution): asset.AssetMap {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, this.alias());
    attributes.set(asset.Tag.SECRET, payload);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, conflict);
    return attributes;
  }

  private async read(): Promise<string> {
    // A first query can fail with DATABASE_ERROR before any asset exists.
    // Initialize with THROW_ERROR, preserving any existing session; only the
    // documented duplicate error is ignored, never a database/access failure.
    try {
      await asset.add(this.attributes(new util.TextEncoder().encodeInto(EMPTY_SESSION),
        asset.ConflictResolution.THROW_ERROR));
    } catch (error) {
      if ((error as BusinessError).code !== 24000003) throw new Error('Asset initialization failed');
    }
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias());
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const records: Array<asset.AssetMap> = await asset.query(query);
    if (records.length !== 1) throw new Error('Invalid asset count');
    const secret = records[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array) || secret.length < 1 || secret.length > 1024) {
      throw new Error('Invalid asset');
    }
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(secret);
  }

  private async execute(call: MethodCall, result: MethodResult): Promise<void> {
    if (this.busy) {
      result.error('secure_storage_busy', '安全存储正在处理，请重试', null);
      return;
    }
    this.busy = true;
    const generation = this.generation;
    try {
      let response: string | null = null;
      if (call.method === 'read') {
        response = await this.read();
      } else {
        const payload = call.method === 'clear' ? EMPTY_SESSION : call.argument('payload') as string;
        if (typeof payload !== 'string') throw new Error('Invalid payload');
        const bytes = new util.TextEncoder().encodeInto(payload);
        if (bytes.length < 1 || bytes.length > 1024) throw new Error('Invalid payload size');
        await asset.add(this.attributes(bytes, asset.ConflictResolution.OVERWRITE));
      }
      if (generation !== this.generation) {
        result.error('secure_storage_detached', '安全存储连接已变化，请重试', null);
        return;
      }
      result.success(response);
    } catch {
      // No payload, token, raw system message or exception stack crosses errors.
      result.error('secure_storage_failed', '系统安全存储操作失败，请重试', null);
    } finally {
      this.busy = false;
    }
  }
}
