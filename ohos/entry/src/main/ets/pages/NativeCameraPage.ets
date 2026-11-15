import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { NativeCameraRequest } from '../NativeCameraPlugin';

@Component
export struct NativeCameraPage {
  @StorageLink('havenNativeCameraCancel') @Watch('onCancelRequested') cancelRequested: boolean = false;
  @State status: string = '正在打开相机';
  @State ready: boolean = false;
  @State capturing: boolean = false;
  @State photoPath: string = '';
  private controller: XComponentController = new XComponentController();
  private input: camera.CameraInput | undefined;
  private preview: camera.PreviewOutput | undefined;
  private output: camera.PhotoOutput | undefined;
  private session: camera.PhotoSession | undefined;
  private context: common.UIAbilityContext | undefined;
  private requestId: number = NativeCameraRequest.id;
  private starting: boolean = false;
  @State saving: boolean = false;
  private closing: boolean = false;
  private finished: boolean = false;
  private accepted: boolean = false;
  private failure: string | undefined;
  private timeoutId: number = -1;

  private onCancelRequested(): void {
    if (this.cancelRequested) this.close();
  }

  private close(error?: string, accepted: boolean = false): void {
    if (this.closing) return;
    this.closing = true;
    this.ready = false;
    this.accepted = accepted;
    this.failure = error;
    clearTimeout(this.timeoutId);
    this.finish();
  }

  private async start(): Promise<void> {
    if (this.starting || this.ready || this.closing) return;
    this.starting = true;
    try {
      this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context, ['ohos.permission.CAMERA']);
      if (this.closing) return;
      if (permission.authResults.length !== 1 || permission.authResults[0] !== 0) {
        this.close('camera_access_denied');
        return;
      }
      const manager = camera.getCameraManager(this.context);
      const devices = manager.getSupportedCameras();
      const device = devices.find((item: camera.CameraDevice) => item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) ?? devices[0];
      if (!device) throw new Error('No camera');
      const capability = manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
      const previewProfile = capability.previewProfiles.find((item: camera.Profile) =>
        item.size.width === 1280 && item.size.height === 720 && item.format === camera.CameraFormat.CAMERA_FORMAT_RGBA_8888);
      const photoProfile = capability.photoProfiles.find((item: camera.Profile) => item.size.width === 1280 && item.size.height === 720);
      if (!previewProfile || !photoProfile) throw new Error('Unsupported camera profile');
      this.input = manager.createCameraInput(device);
      await this.input.open();
      if (this.closing) return;
      this.preview = manager.createPreviewOutput(previewProfile, this.controller.getXComponentSurfaceId());
      this.output = manager.createPhotoOutput(photoProfile);
      this.output.on('photoAvailable', (error: BusinessError, photo: camera.Photo) => {
        if (error && error.code !== 0) {
          photo?.release().catch(() => {});
          this.close('camera_capture_failed');
          return;
        }
        this.save(photo);
      });
      this.output.on('error', (_error: BusinessError) => this.close('camera_capture_failed'));
      this.session = manager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
      this.session.on('error', (_error: BusinessError) => this.close('camera_capture_failed'));
      this.session.beginConfig();
      this.session.addInput(this.input);
      this.session.addOutput(this.preview);
      this.session.addOutput(this.output);
      await this.session.commitConfig();
      if (this.closing) return;
      await this.session.start();
      if (this.closing) return;
      this.ready = true;
      this.status = '请将内容放入取景框';
    } catch (_) {
      this.close('camera_unavailable');
    } finally {
      this.starting = false;
      if (this.closing) await this.finish();
    }
  }

  private async capture(): Promise<void> {
    if (!this.ready || this.capturing || this.closing || !this.output) return;
    this.capturing = true;
    this.status = '正在拍照';
    this.timeoutId = setTimeout(() => this.close('camera_capture_failed'), 10000);
    try {
      await this.output.capture({ quality: camera.QualityLevel.QUALITY_LEVEL_HIGH });
    } catch (_) { this.close('camera_capture_failed'); }
  }

  private async save(photo: camera.Photo): Promise<void> {
    if (!photo) { this.close('camera_capture_failed'); return; }
    if (this.closing || this.saving || !this.capturing || !this.context) {
      try { await photo.release(); } catch (_) {}
      return;
    }
    this.saving = true;
    clearTimeout(this.timeoutId);
    let path = '';
    try {
      const component = await photo.main.getComponent(image.ComponentType.JPEG);
      const bytes = new Uint8Array(component.byteBuffer);
      if (bytes.length < 3 || bytes[0] !== 255 || bytes[1] !== 216) throw new Error('Invalid capture');
      const source = image.createImageSource(component.byteBuffer);
      let encoded: ArrayBuffer;
      try {
        const info = await source.getImageInfo();
        if (info.size.width <= 0 || info.size.height <= 0 || info.size.width * info.size.height > 1280 * 720) {
          throw new Error('Invalid photo dimensions');
        }
        const packer = image.createImagePacker();
        try { encoded = await packer.packing(source, { format: 'image/jpeg', quality: NativeCameraRequest.quality }); }
        finally { await packer.release(); }
      } finally { await source.release(); }
      if (this.closing) return;
      const directory = `${this.context.cacheDir}/native-camera`;
      if (!fs.accessSync(directory)) fs.mkdirSync(directory);
      // Returned photos remain readable by Flutter; only old owned files expire.
      for (const name of fs.listFileSync(directory)) {
        if (!/^photo-[0-9]+-[0-9]+[.]jpg$/.test(name)) continue;
        const timestamp = Number(name.split('-')[1]);
        if (Date.now() - timestamp > 24 * 60 * 60 * 1000) {
          try { fs.unlinkSync(`${directory}/${name}`); } catch (_) {}
        }
      }
      path = `${directory}/photo-${Date.now()}-${this.requestId}.jpg`;
      const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        if (await fs.write(file.fd, encoded) !== encoded.byteLength) throw new Error('Incomplete photo');
      } finally { await fs.close(file); }
      if (this.closing) return;
      this.photoPath = path;
      path = '';
      this.status = '确认照片后使用';
    } catch (_) {
      this.close('camera_capture_failed');
    } finally {
      if (path.length > 0) { try { fs.unlinkSync(path); } catch (_) {} }
      try { await photo.release(); } catch (_) {}
      // Release the captured buffer before stopping its producer, otherwise
      // the emulator can wait indefinitely for the outstanding photo buffer.
      await this.releaseCamera();
      this.saving = false;
      this.capturing = false;
      if (this.closing) await this.finish();
    }
  }

  private async releaseCamera(): Promise<void> {
    this.ready = false;
    const session = this.session; this.session = undefined;
    const input = this.input; this.input = undefined;
    const preview = this.preview; this.preview = undefined;
    const output = this.output; this.output = undefined;
    try { await session?.stop(); } catch (_) {}
    try { await input?.close(); } catch (_) {}
    try { await preview?.release(); } catch (_) {}
    try { await output?.release(); } catch (_) {}
    try { await session?.release(); } catch (_) {}
  }

  private async retake(): Promise<void> {
    if (this.saving || this.closing) return;
    try { if (this.photoPath) fs.unlinkSync(this.photoPath); } catch (_) {}
    this.photoPath = '';
    this.status = '正在打开相机';
    // XComponent stays mounted under the captured image.
    await this.start();
  }

  private async finish(): Promise<void> {
    if (!this.closing || this.starting || this.saving || this.finished) return;
    this.finished = true;
    await this.releaseCamera();
    if (!this.accepted && this.photoPath) {
      try { fs.unlinkSync(this.photoPath); } catch (_) {}
    }
    NativeCameraRequest.complete(this.requestId, this.accepted ? this.photoPath : null, this.failure);
  }

  aboutToDisappear(): void { this.close(); }

  build() {
    Column({ space: 16 }) {
      Row() {
        Button('取消').onClick(() => this.close())
        Text('拍照').fontSize(22).fontColor(Color.White).layoutWeight(1).textAlign(TextAlign.Center)
      }.width('100%')
      Stack() {
        XComponent({ id: 'havenNativeCamera', type: XComponentType.SURFACE, controller: this.controller })
          .width('100%').height('100%').onLoad(() => this.start())
        if (this.photoPath.length > 0) {
          Image(`file://${this.photoPath}`).width('100%').height('100%').objectFit(ImageFit.Contain).backgroundColor(Color.Black)
        }
      }.width('100%').layoutWeight(1)
      Text(this.status).fontSize(16).fontColor(Color.White)
      if (this.photoPath.length > 0) {
        Row({ space: 24 }) {
          Button('重拍').enabled(!this.saving).onClick(() => this.retake())
          Button('使用照片').enabled(!this.saving).onClick(() => this.close(undefined, true))
        }
      } else {
        Button('拍照').enabled(this.ready && !this.capturing).onClick(() => this.capture())
      }
    }.width('100%').height('100%').padding({ top: 24, bottom: 40, left: 20, right: 20 }).backgroundColor(Color.Black)
  }
}
