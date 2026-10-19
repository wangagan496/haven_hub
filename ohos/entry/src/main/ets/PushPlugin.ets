import { AbilityAware, AbilityPluginBinding, FlutterPlugin, FlutterPluginBinding,
  MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { common, Want } from '@kit.AbilityKit';
import { pushService, pushCommon } from '@kit.PushKit';
import { notificationManager } from '@kit.NotificationKit';

/** Push tokens stay on the local bridge; service-account keys never enter the app. */
export default class PushPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: common.UIAbilityContext | null = null;
  private notificationId: string = '';
  private profileId: string = '';
  private busy: boolean = false;
  private generation: number = 0;

  getUniqueClassName(): string { return 'PushPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'haven_hub/push');
    this.channel.setMethodCallHandler(this);
  }
  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.generation++;
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.context = null;
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void { this.context = binding.getAbility().context; }
  onDetachedFromAbility(): void { this.generation++; this.context = null; }
  receiveWant(want: Want): void {
    const id = want.parameters?.['notificationId'];
    if (typeof id === 'string' && /^[a-f0-9-]{36}$/.test(id)) this.notificationId = id;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'takeClick') {
      result.success({ notificationId: this.notificationId });
      this.notificationId = '';
      return;
    }
    if (call.method === 'requestPermission') { this.requestPermission(result); return; }
    if (call.method === 'disable') { this.disable(call,result); return; }
    if (call.method === 'enable' || call.method === 'resume') { this.enable(call,result); return; }
    result.notImplemented();
  }
  private async requestPermission(result: MethodResult): Promise<void> {
    if (this.context === null) { result.error('unavailable', '通知服务尚未就绪', null); return; }
    try { await notificationManager.requestEnableNotification(this.context); result.success({}); }
    catch { result.error('denied', '系统通知未获授权，待办仍会保留', null); }
  }
  private async enable(call: MethodCall, result: MethodResult): Promise<void> {
    const context = this.context;
    if (context === null || this.busy) { result.error('busy', '通知服务尚未就绪，请重试', null); return; }
    const profileId = call.argument('profileId') as string;
    if (!profileId || !/^[a-f0-9]{64}$/.test(profileId)) { result.error('invalid_profile', '账号通知标识无效', null); return; }
    this.busy = true;
    const generation = this.generation;
    try {
      const allowed = await notificationManager.isNotificationEnabled();
      if (!allowed) { result.error('denied', '请在系统设置中允许通知，待办仍会保留', null); return; }
      const token = await pushService.getToken();
      if (generation !== this.generation) { result.error('cancelled', '登录状态已变化，请重试', null); return; }
      await pushService.bindAppProfileId(pushCommon.AppProfileType.PROFILE_TYPE_APPLICATION_ACCOUNT, profileId);
      if (generation !== this.generation) {
        await pushService.unbindAppProfileId(profileId);
        result.error('cancelled', '登录状态已变化，请重试', null);
        return;
      }
      this.profileId = profileId;
      result.success({ platform: 'harmony', token: token });
    } catch {
      result.error('push_unavailable', '鸿蒙推送登记失败，请核对通知权限、Push Kit 能力和应用签名', null);
    } finally { this.busy = false; }
  }
  private async disable(call: MethodCall, result: MethodResult): Promise<void> {
    this.generation++;
    this.notificationId = '';
    const argument: string | null = call.argument('profileId') as string | null;
    // 与 enable 相同的格式校验；格式不对的值不传给系统接口，只清理本地状态。
    const savedProfile: string = typeof argument === 'string' && /^[a-f0-9]{64}$/.test(argument) ? argument : '';
    const profile = this.profileId || savedProfile;
    let unbound = profile === '';
    if (profile) {
      try { await pushService.unbindAppProfileId(profile); unbound = true; this.profileId = ''; } catch { /* 下面单独报告。 */ }
    }
    // 通知栏清理与 profile 解绑互不影响：本应用只通过 Push Kit 显示报修通知，
    // 退出或停用时全部清掉，避免换号后旧账号的通知仍留在通知栏。
    let cleared = false;
    try { await notificationManager.cancelAll(); cleared = true; } catch { /* 下面单独报告。 */ }
    if (unbound && cleared) result.success({ disabled: true });
    else if (!unbound) result.error('unbind_failed', '系统通知解绑未完成，请重试', null);
    else result.error('clear_failed', '通知栏清理未完成，请重试', null);
  }
}
